#include "file_open_channel.h"

#include <glib.h>
#include <flutter_linux/flutter_linux.h>

#include <deque>
#include <string>
#include <vector>

namespace {

constexpr char kChannelName[] = "org.oroncanopy.oronbox/file_open";

FlMethodChannel* g_channel = nullptr;
std::deque<std::string> g_pending_paths;
bool g_dart_ready = false;

void queue_path(const char* path) {
  if (path == nullptr || path[0] == '\0') {
    return;
  }
  g_pending_paths.emplace_back(path);
}

void flush() {
  if (g_channel == nullptr || !g_dart_ready) {
    return;
  }
  while (!g_pending_paths.empty()) {
    std::string path = std::move(g_pending_paths.front());
    g_pending_paths.pop_front();
    g_autoptr(FlValue) args = fl_value_new_string(path.c_str());
    fl_method_channel_invoke_method(g_channel, "openFile", args, nullptr,
                                    nullptr, nullptr);
  }
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                    gpointer user_data) {
  const gchar* method = fl_method_call_get_name(method_call);
  if (g_strcmp0(method, "getInitialFile") == 0) {
    g_dart_ready = true;
    if (g_pending_paths.empty()) {
      fl_method_call_respond_success(method_call,
                                     fl_value_new_string(""), nullptr);
    } else {
      std::string path = std::move(g_pending_paths.front());
      g_pending_paths.pop_front();
      fl_method_call_respond_success(method_call,
                                     fl_value_new_string(path.c_str()), nullptr);
    }
    flush();
    return;
  }
  fl_method_call_respond_not_implemented(method_call, nullptr);
}

}  // namespace

void file_open_channel_register(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, kChannelName,
                                    FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, nullptr,
                                            nullptr);
}

void file_open_channel_queue(const char* path) { queue_path(path); }

void file_open_channel_flush() { flush(); }
