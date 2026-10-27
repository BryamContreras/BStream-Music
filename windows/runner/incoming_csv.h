#ifndef RUNNER_INCOMING_CSV_H_
#define RUNNER_INCOMING_CSV_H_

#include <windows.h>
#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <memory>
#include <cstdint>
#include <optional>
#include <string>
#include <vector>

std::optional<std::wstring> IncomingCsvArgument();
bool ForwardCsvToInstance(const std::wstring& path);

class IncomingCsvBridge {
 public:
  explicit IncomingCsvBridge(flutter::BinaryMessenger* messenger);
  bool HandleMessage(UINT message, WPARAM wparam, LPARAM lparam);

 private:
  void Accept(const std::wstring& path);
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::vector<flutter::EncodableValue> pending_;
  bool ready_ = false;
  uint64_t serial_ = 0;
};

#endif
