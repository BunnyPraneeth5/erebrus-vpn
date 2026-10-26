#include "protocol_registration.h"

#include <windows.h>

#include <string>

namespace {

// Per-user URL protocol association.
//
// HKEY_CURRENT_USER\Software\Classes is deliberate and the only hive touched:
// it needs no elevation and merges into HKEY_CLASSES_ROOT for this user alone.
// Never HKEY_LOCAL_MACHINE, and never any Run / RunOnce / startup key — this is
// a URL scheme association and nothing else.
constexpr wchar_t kProtocolKey[] = L"Software\\Classes\\erebrusvpn";
constexpr wchar_t kIconKey[] = L"Software\\Classes\\erebrusvpn\\DefaultIcon";
constexpr wchar_t kCommandKey[] =
    L"Software\\Classes\\erebrusvpn\\shell\\open\\command";

constexpr wchar_t kProtocolDescription[] = L"URL:Erebrus VPN Protocol";

// The presence of this value — not its content — is what marks the key as a
// URL protocol handler, so it is written empty.
constexpr wchar_t kUrlProtocolValue[] = L"URL Protocol";

std::wstring ExecutablePath() {
  // GetModuleFileNameW truncates rather than failing, so grow the buffer until
  // the path fits instead of trusting MAX_PATH.
  std::wstring path(MAX_PATH, L'\0');
  for (;;) {
    const DWORD written = ::GetModuleFileNameW(
        nullptr, path.data(), static_cast<DWORD>(path.size()));
    if (written == 0) {
      return std::wstring();
    }
    if (written < path.size()) {
      path.resize(written);
      return path;
    }
    if (path.size() >= UNICODE_STRING_MAX_CHARS) {
      return std::wstring();
    }
    path.resize(path.size() * 2);
  }
}

// Reads a key's default (unnamed) REG_SZ value. Returns empty when the key or
// value is missing.
std::wstring ReadDefaultValue(const wchar_t* subkey) {
  DWORD bytes = 0;
  if (::RegGetValueW(HKEY_CURRENT_USER, subkey, nullptr, RRF_RT_REG_SZ, nullptr,
                     nullptr, &bytes) != ERROR_SUCCESS ||
      bytes < sizeof(wchar_t)) {
    return std::wstring();
  }
  std::wstring value(bytes / sizeof(wchar_t), L'\0');
  if (::RegGetValueW(HKEY_CURRENT_USER, subkey, nullptr, RRF_RT_REG_SZ, nullptr,
                     value.data(), &bytes) != ERROR_SUCCESS) {
    return std::wstring();
  }
  value.resize(::wcsnlen(value.c_str(), value.size()));
  return value;
}

// `URL Protocol` is stored empty, so an existence check is needed rather than a
// value comparison.
bool ValueExists(const wchar_t* subkey, const wchar_t* name) {
  DWORD bytes = 0;
  return ::RegGetValueW(HKEY_CURRENT_USER, subkey, name, RRF_RT_REG_SZ, nullptr,
                        nullptr, &bytes) == ERROR_SUCCESS;
}

bool WriteString(const wchar_t* subkey,
                 const wchar_t* name,
                 const std::wstring& value) {
  HKEY key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, subkey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                        nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const DWORD bytes = static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  const LSTATUS status =
      ::RegSetValueExW(key, name, 0, REG_SZ,
                       reinterpret_cast<const BYTE*>(value.c_str()), bytes);
  ::RegCloseKey(key);
  return status == ERROR_SUCCESS;
}

}  // namespace

bool EnsureProtocolRegistered() {
  const std::wstring exe = ExecutablePath();
  if (exe.empty()) {
    return false;
  }

  // `%1` must stay quoted or links containing spaces arrive truncated.
  const std::wstring command = L"\"" + exe + L"\" \"%1\"";

  // Read-compare-skip: a correctly registered app writes nothing on launch.
  // Both halves matter — a partially written claim (command present but the
  // `URL Protocol` marker missing) must still be repaired.
  if (_wcsicmp(ReadDefaultValue(kCommandKey).c_str(), command.c_str()) == 0 &&
      ValueExists(kProtocolKey, kUrlProtocolValue)) {
    return true;
  }

  // "Last launched wins": a debug build run from `flutter run` and an installed
  // release build will take this claim from each other. That is expected and
  // accepted — with no installer to own the registration, the exe that ran most
  // recently is the only sensible owner, and it is also what makes the scheme
  // testable during development.
  return WriteString(kProtocolKey, nullptr, kProtocolDescription) &&
         WriteString(kProtocolKey, kUrlProtocolValue, std::wstring()) &&
         WriteString(kIconKey, nullptr, L"\"" + exe + L"\",0") &&
         WriteString(kCommandKey, nullptr, command);
}
