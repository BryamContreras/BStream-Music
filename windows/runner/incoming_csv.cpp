#include "incoming_csv.h"

#include <shellapi.h>
#include <flutter/standard_method_codec.h>

namespace {
constexpr ULONG_PTR kCsvMessage = 0x42534356;

bool IsCsv(const std::wstring& path) {
  return path.size() > 4 &&
         _wcsicmp(path.substr(path.size() - 4).c_str(), L".csv") == 0 &&
         path.find(L"://") == std::wstring::npos;
}

std::string Utf8(const std::wstring& value) {
  const int count = WideCharToMultiByte(CP_UTF8, 0, value.data(),
      static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
  std::string result(count, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                     result.data(), count, nullptr, nullptr);
  return result;
}

bool SameExecutable(DWORD pid) {
  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
  if (!process) return false;
  wchar_t candidate[32768] = {};
  wchar_t ours[32768] = {};
  DWORD length = ARRAYSIZE(candidate);
  const bool valid = QueryFullProcessImageNameW(process, 0, candidate, &length) &&
      GetModuleFileNameW(nullptr, ours, ARRAYSIZE(ours)) &&
      _wcsicmp(candidate, ours) == 0;
  CloseHandle(process);
  return valid;
}
}  // namespace

std::optional<std::wstring> IncomingCsvArgument() {
  int count = 0;
  auto arguments = CommandLineToArgvW(GetCommandLineW(), &count);
  if (!arguments) return std::nullopt;
  std::wstring path = count == 2 ? arguments[1] : L"";
  LocalFree(arguments);
  if (!IsCsv(path)) return std::nullopt;
  const DWORD length = GetFullPathNameW(path.c_str(), 0, nullptr, nullptr);
  if (!length) return std::nullopt;
  std::wstring absolute(length, L'\0');
  const DWORD written = GetFullPathNameW(path.c_str(), length, absolute.data(), nullptr);
  if (!written || written >= length) return std::nullopt;
  absolute.resize(written);
  return absolute;
}

bool ForwardCsvToInstance(const std::wstring& path) {
  HWND found = nullptr;
  EnumWindows([](HWND window, LPARAM state) -> BOOL {
    wchar_t class_name[64] = {};
    GetClassNameW(window, class_name, ARRAYSIZE(class_name));
    if (_wcsicmp(class_name, L"FLUTTER_RUNNER_WIN32_WINDOW") != 0) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(window, &pid);
    if (pid != GetCurrentProcessId() && SameExecutable(pid)) {
      *reinterpret_cast<HWND*>(state) = window;
      return FALSE;
    }
    return TRUE;
  }, reinterpret_cast<LPARAM>(&found));
  if (!found) return false;
  COPYDATASTRUCT data = {};
  data.dwData = kCsvMessage;
  data.cbData = static_cast<DWORD>((path.size() + 1) * sizeof(wchar_t));
  data.lpData = const_cast<wchar_t*>(path.c_str());
  DWORD_PTR accepted = 0;
  if (!SendMessageTimeoutW(found, WM_COPYDATA, GetCurrentProcessId(),
      reinterpret_cast<LPARAM>(&data), SMTO_ABORTIFHUNG, 3000, &accepted) ||
      !accepted) return false;
  if (IsIconic(found)) ShowWindow(found, SW_RESTORE);
  SetForegroundWindow(found);
  return true;
}

IncomingCsvBridge::IncomingCsvBridge(flutter::BinaryMessenger* messenger) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "bstream_music/incoming_csv",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    if (call.method_name() == "start") {
      ready_ = true;
      result->Success(flutter::EncodableValue(pending_));
      pending_.clear();
    } else if (call.method_name() == "stop") {
      ready_ = false;
      result->Success();
    } else if (call.method_name() == "release") {
      result->Success();  // Desktop originals are never owned by BStream.
    } else {
      result->NotImplemented();
    }
  });
  if (const auto path = IncomingCsvArgument()) Accept(*path);
}

void IncomingCsvBridge::Accept(const std::wstring& path) {
  if (!IsCsv(path)) return;
  const auto separator = path.find_last_of(L"\\/");
  const auto name = path.substr(separator == std::wstring::npos ? 0 : separator + 1);
  using flutter::EncodableValue;
  flutter::EncodableMap event = {
      {EncodableValue("id"), EncodableValue(std::to_string(GetTickCount64()) + "-" + std::to_string(++serial_))},
      {EncodableValue("path"), EncodableValue(Utf8(path))},
      {EncodableValue("name"), EncodableValue(Utf8(name))},
      {EncodableValue("source"), EncodableValue(Utf8(path))},
      {EncodableValue("temporary"), EncodableValue(false)},
  };
  if (!ready_) {
    pending_.emplace_back(event);
  } else {
    channel_->InvokeMethod("open", std::make_unique<EncodableValue>(event));
  }
}

bool IncomingCsvBridge::HandleMessage(UINT message, WPARAM wparam, LPARAM lparam) {
  if (message != WM_COPYDATA || !lparam) return false;
  const auto* data = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
  if (data->dwData != kCsvMessage || !data->lpData ||
      data->cbData < sizeof(wchar_t) || data->cbData > 65536 ||
      data->cbData % sizeof(wchar_t) != 0 ||
      !SameExecutable(static_cast<DWORD>(wparam))) return false;
  std::wstring path(static_cast<const wchar_t*>(data->lpData),
                    data->cbData / sizeof(wchar_t));
  const auto zero = path.find(L'\0');
  if (zero != std::wstring::npos) path.resize(zero);
  if (!IsCsv(path)) return false;
  Accept(path);
  return true;
}
