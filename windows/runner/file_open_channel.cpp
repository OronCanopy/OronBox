#include "file_open_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

namespace {

using flutter::EncodableValue;
using flutter::MethodChannel;
using flutter::StandardMethodCodec;

std::string g_initial_path;

void HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  if (call.method_name() == "getInitialFile") {
    if (g_initial_path.empty()) {
      result->Success();
    } else {
      result->Success(EncodableValue(g_initial_path));
    }
    return;
  }
  result->NotImplemented();
}

}  // namespace

void RegisterFileOpenChannel(flutter::BinaryMessenger* messenger,
                             const std::string& initial_path) {
  g_initial_path = initial_path;
  auto channel = std::make_unique<MethodChannel<EncodableValue>>(
      messenger, "org.oroncanopy.oronbox/file_open", &StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(&HandleMethodCall);
  // Keep the channel alive for the process lifetime so Dart can query
  // getInitialFile whenever the first frame is ready.
  static std::unique_ptr<MethodChannel<EncodableValue>> g_channel;
  g_channel = std::move(channel);
}
