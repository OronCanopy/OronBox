#include "runner_startup.h"

#include <windows.h>

#include <algorithm>
#include <cctype>
#include <cstring>

namespace {

void SetRegistryString(HKEY key, const wchar_t* name,
                       const std::wstring& value) {
  ::RegSetValueExW(key, name, 0, REG_SZ,
                   reinterpret_cast<const BYTE*>(value.c_str()),
                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)));
}

}  // namespace

void RegisterOronBoxUrlProtocol() {
  wchar_t executable_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, executable_path, MAX_PATH) == 0) return;

  HKEY protocol_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, L"Software\\Classes\\oronbox", 0,
                        nullptr, 0, KEY_WRITE, nullptr, &protocol_key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }
  SetRegistryString(protocol_key, nullptr, L"URL:OronBox Protocol");
  SetRegistryString(protocol_key, L"URL Protocol", L"");

  HKEY command_key = nullptr;
  if (::RegCreateKeyExW(protocol_key, L"shell\\open\\command", 0, nullptr,
                        0, KEY_WRITE, nullptr, &command_key,
                        nullptr) == ERROR_SUCCESS) {
    SetRegistryString(command_key, nullptr,
                      L"\"" + std::wstring(executable_path) + L"\" \"%1\"");
    ::RegCloseKey(command_key);
  }
  ::RegCloseKey(protocol_key);
}

void RegisterOronBoxFileAssociations() {
  wchar_t executable_path[MAX_PATH];
  if (::GetModuleFileNameW(nullptr, executable_path, MAX_PATH) == 0) return;

  const wchar_t* extensions[] = {L".rpk", L".bin", L".face", L".zpk",
                                 L".mwz", L".obp", L".abp", L".canopus",
                                 L".crpack"};
  const wchar_t* descriptions[] = {
      L"OronBox RPK Package", L"OronBox Firmware", L"OronBox Watchface",
      L"OronBox ZPK Package", L"OronBox MWZ Project",
      L"OronBox Plugin Package", L"AstroBox Plugin Package",
      L"OronBox Canopus Module"};
  const std::wstring command =
      L"\"" + std::wstring(executable_path) + L"\" \"%1\"";
  for (int i = 0; i < 8; i++) {
    std::wstring class_name = std::wstring(L"OronBox.") + (extensions[i] + 1);
    HKEY class_key = nullptr;
    if (::RegCreateKeyExW(HKEY_CURRENT_USER,
                          (L"Software\\Classes\\" + class_name).c_str(), 0,
                          nullptr, 0, KEY_WRITE, nullptr, &class_key,
                          nullptr) != ERROR_SUCCESS) {
      continue;
    }
    SetRegistryString(class_key, nullptr, descriptions[i]);
    HKEY open_with_key = nullptr;
    if (::RegCreateKeyExW(class_key, L"shell\\open", 0, nullptr, 0, KEY_WRITE,
                          nullptr, &open_with_key, nullptr) == ERROR_SUCCESS) {
      HKEY command_key = nullptr;
      if (::RegCreateKeyExW(open_with_key, L"command", 0, nullptr, 0,
                            KEY_WRITE, nullptr, &command_key,
                            nullptr) == ERROR_SUCCESS) {
        SetRegistryString(command_key, nullptr, command);
        ::RegCloseKey(command_key);
      }
      ::RegCloseKey(open_with_key);
    }
    ::RegCloseKey(class_key);

    HKEY ext_key = nullptr;
    if (::RegCreateKeyExW(
            HKEY_CURRENT_USER,
            (L"Software\\Classes\\" + std::wstring(extensions[i])).c_str(),
            0, nullptr, 0, KEY_WRITE, nullptr, &ext_key,
            nullptr) == ERROR_SUCCESS) {
      SetRegistryString(ext_key, nullptr, class_name);
      ::RegCloseKey(ext_key);
    }
  }
}

std::string OronBoxFilePathFromArguments(
    const std::vector<std::string>& arguments) {
  for (const std::string& argument : arguments) {
    if (argument.empty() || argument[0] == '-') continue;
    std::string lower = argument;
    std::transform(lower.begin(), lower.end(), lower.begin(),
                   [](unsigned char value) {
                     return static_cast<char>(std::tolower(value));
                   });
    for (const char* extension : {".rpk", ".bin", ".face", ".zpk", ".mwz",
                                  ".obp", ".abp", ".canopus", ".crpack", ".zip",
                                  ".tar"}) {
      const auto length = std::strlen(extension);
      if (lower.size() >= length &&
          lower.compare(lower.size() - length, length, extension) == 0) {
        return argument;
      }
    }
  }
  return "";
}
