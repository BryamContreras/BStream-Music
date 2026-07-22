#include "app_identity.h"

#include <windows.h>
#include <propkey.h>
#include <propvarutil.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <wrl/client.h>

#include <string>
#include <vector>

namespace {

// Keep this value in sync with the AppUserModelID assigned by the installer.
constexpr wchar_t kAppUserModelId[] = L"BStreamMusic.Desktop";
constexpr wchar_t kShortcutName[] = L"BStream Music.lnk";

void LogIdentityError(const wchar_t* message, HRESULT result) {
  wchar_t buffer[256] = {};
  ::swprintf_s(buffer, L"BStream Music: %s (HRESULT 0x%08X)\n", message,
               static_cast<unsigned int>(result));
  ::OutputDebugStringW(buffer);
}

HRESULT GetExecutablePath(std::wstring* executable_path) {
  std::vector<wchar_t> buffer(32768);
  const DWORD length = ::GetModuleFileNameW(
      nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
  if (length == 0) {
    return HRESULT_FROM_WIN32(::GetLastError());
  }
  if (length >= buffer.size()) {
    return HRESULT_FROM_WIN32(ERROR_INSUFFICIENT_BUFFER);
  }

  executable_path->assign(buffer.data(), length);
  return S_OK;
}

HRESULT GetShortcutPath(std::wstring* shortcut_path) {
  PWSTR programs_path = nullptr;
  const HRESULT result = ::SHGetKnownFolderPath(
      FOLDERID_Programs, KF_FLAG_CREATE, nullptr, &programs_path);
  if (FAILED(result)) {
    return result;
  }

  shortcut_path->assign(programs_path);
  ::CoTaskMemFree(programs_path);
  if (!shortcut_path->empty() && shortcut_path->back() != L'\\') {
    shortcut_path->push_back(L'\\');
  }
  shortcut_path->append(kShortcutName);
  return S_OK;
}

HRESULT CreateOrUpdateStartMenuShortcut() {
  std::wstring executable_path;
  HRESULT result = GetExecutablePath(&executable_path);
  if (FAILED(result)) {
    return result;
  }

  std::wstring shortcut_path;
  result = GetShortcutPath(&shortcut_path);
  if (FAILED(result)) {
    return result;
  }

  Microsoft::WRL::ComPtr<IShellLinkW> shell_link;
  result = ::CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(shell_link.GetAddressOf()));
  if (FAILED(result)) {
    return result;
  }

  Microsoft::WRL::ComPtr<IPersistFile> persist_file;
  result = shell_link.As(&persist_file);
  if (FAILED(result)) {
    return result;
  }

  const bool shortcut_exists =
      ::GetFileAttributesW(shortcut_path.c_str()) != INVALID_FILE_ATTRIBUTES;
  if (shortcut_exists) {
    result = persist_file->Load(shortcut_path.c_str(), STGM_READWRITE);
    if (FAILED(result)) {
      return result;
    }
  } else {
    result = shell_link->SetPath(executable_path.c_str());
    if (FAILED(result)) {
      return result;
    }

    const size_t separator = executable_path.find_last_of(L"\\/");
    if (separator != std::wstring::npos) {
      result = shell_link->SetWorkingDirectory(
          executable_path.substr(0, separator).c_str());
      if (FAILED(result)) {
        return result;
      }
    }

    shell_link->SetDescription(L"BStream Music");
    shell_link->SetIconLocation(executable_path.c_str(), 0);
  }

  Microsoft::WRL::ComPtr<IPropertyStore> property_store;
  result = shell_link.As(&property_store);
  if (FAILED(result)) {
    return result;
  }

  PROPVARIANT app_id;
  ::PropVariantInit(&app_id);
  result = ::InitPropVariantFromString(kAppUserModelId, &app_id);
  if (SUCCEEDED(result)) {
    result = property_store->SetValue(PKEY_AppUserModel_ID, app_id);
  }
  ::PropVariantClear(&app_id);
  if (FAILED(result)) {
    return result;
  }

  result = property_store->Commit();
  if (FAILED(result)) {
    return result;
  }

  result = persist_file->Save(shortcut_path.c_str(), TRUE);
  if (FAILED(result)) {
    return result;
  }

  ::SHChangeNotify(shortcut_exists ? SHCNE_UPDATEITEM : SHCNE_CREATE,
                   SHCNF_PATHW, shortcut_path.c_str(), nullptr);
  return S_OK;
}

}  // namespace

void RegisterWindowsAppIdentity() {
  HRESULT result =
      ::SetCurrentProcessExplicitAppUserModelID(kAppUserModelId);
  if (FAILED(result)) {
    LogIdentityError(L"could not set the process AppUserModelID", result);
    return;
  }

  result = CreateOrUpdateStartMenuShortcut();
  if (FAILED(result)) {
    LogIdentityError(L"could not register the Start menu shortcut", result);
  }
}
