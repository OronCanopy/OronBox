#ifndef FLUTTER_FILE_OPEN_CHANNEL_H_
#define FLUTTER_FILE_OPEN_CHANNEL_H_

#include <flutter_linux/flutter_linux.h>

// Registers the "org.oroncanopy.oronbox/file_open" channel. Files opened with OronBox from a
// file manager arrive through the GApplication "open" signal; paths are queued
// until the Dart handler is ready (cold start pulls with getInitialFile).
void file_open_channel_register(FlBinaryMessenger* messenger);
void file_open_channel_queue(const char* path);
void file_open_channel_flush();

#endif  // FLUTTER_FILE_OPEN_CHANNEL_H_
