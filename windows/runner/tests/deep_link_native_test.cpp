#include <windows.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <string>
#include <utility>

#include "../deep_link_plugin.h"
#include "../protocol_registration.h"
#include "../single_instance.h"
#include "../utils.h"

namespace {

int main_token;
int receiver_token;
int mutex_token;
int module_token;
int key_token;
const HWND main_handle = reinterpret_cast<HWND>(&main_token);
const HWND receiver_handle = reinterpret_cast<HWND>(&receiver_token);
const HANDLE mutex_handle = reinterpret_cast<HANDLE>(&mutex_token);
const HMODULE module_handle = reinterpret_cast<HMODULE>(&module_token);
const HKEY key_handle = reinterpret_cast<HKEY>(&key_token);

struct State {
  DWORD error = ERROR_SUCCESS;
  bool mutex_fails = false;
  bool main_valid = true;
  bool register_fails = false;
  bool window_fails = false;
  bool dispatch_accepts = true;
  bool conversion_fails = false;
  bool iconic = false;
  bool transport_succeeds = true;
  bool deliver_to_receiver = true;
  DWORD_PTR acknowledgement = TRUE;
  int absent_polls = 0;
  int find_calls = 0;
  int sleep_calls = 0;
  int send_calls = 0;
  int close_calls = 0;
  int create_window_calls = 0;
  int destroy_calls = 0;
  int unregister_calls = 0;
  int dispatch_calls = 0;
  int show_calls = 0;
  int show_command = 0;
  int foreground_calls = 0;
  int registry_create_calls = 0;
  int registry_set_calls = 0;
  int registry_close_calls = 0;
  int fail_create_at = 0;
  int fail_set_at = 0;
  std::wstring executable = L"C:\\Test App\\erebrus.exe";
  std::wstring opened_subkey;
  std::string dispatched_link;
  std::map<std::pair<std::wstring, std::wstring>, std::wstring> registry;
};

State state;
int checks = 0;

void Check(bool condition, const char* label) {
  ++checks;
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", label);
    std::exit(EXIT_FAILURE);
  }
}

}

HANDLE WINAPI FakeCreateMutexW(LPSECURITY_ATTRIBUTES attributes, BOOL owner,
                               LPCWSTR name) {
  Check(attributes == nullptr && owner == TRUE, "mutex default security");
  Check(std::wstring(name) == L"Local\\ErebrusVpnSingleInstance",
        "session-local mutex name unchanged");
  return state.mutex_fails ? nullptr : mutex_handle;
}

DWORD WINAPI FakeGetLastError() { return state.error; }
BOOL WINAPI FakeCloseHandle(HANDLE handle) {
  Check(handle == mutex_handle, "only fake mutex closed");
  ++state.close_calls;
  return TRUE;
}
HWND WINAPI FakeFindWindowExW(HWND parent, HWND after, LPCWSTR name,
                              LPCWSTR title) {
  Check(parent == HWND_MESSAGE && after == nullptr && title == nullptr,
        "message-only receiver lookup");
  Check(std::wstring(name) == L"ErebrusVpnDeepLinkReceiver", "receiver class");
  return ++state.find_calls <= state.absent_polls ? nullptr : receiver_handle;
}
void WINAPI FakeSleep(DWORD delay) {
  Check(delay == 100, "bounded retry interval");
  ++state.sleep_calls;
}
BOOL WINAPI FakeIsWindow(HWND window) {
  return window == main_handle && state.main_valid;
}
BOOL WINAPI FakeIsIconic(HWND window) {
  Check(window == main_handle, "iconic query uses main window");
  return state.iconic;
}
BOOL WINAPI FakeShowWindow(HWND window, int command) {
  Check(window == main_handle, "only main window surfaced");
  ++state.show_calls;
  state.show_command = command;
  return TRUE;
}
BOOL WINAPI FakeSetForegroundWindow(HWND window) {
  Check(window == main_handle, "only main window focused");
  ++state.foreground_calls;
  return TRUE;
}
DWORD WINAPI FakeGetWindowThreadProcessId(HWND window, LPDWORD process_id) {
  Check(window == receiver_handle, "receiver process lookup");
  *process_id = 123;
  return 456;
}
BOOL WINAPI FakeAllowSetForegroundWindow(DWORD process_id) {
  Check(process_id == 123, "foreground permission targets receiver");
  return TRUE;
}
LRESULT WINAPI FakeDefWindowProcW(HWND, UINT, WPARAM, LPARAM) { return 17; }
HMODULE WINAPI FakeGetModuleHandleW(LPCWSTR name) {
  Check(name == nullptr, "current module requested");
  return module_handle;
}
ATOM WINAPI FakeRegisterClassW(const WNDCLASSW* window_class) {
  Check(window_class->hInstance == module_handle, "receiver module");
  return state.register_fails ? 0 : 1;
}
HWND WINAPI FakeCreateWindowExW(DWORD, LPCWSTR, LPCWSTR, DWORD, int, int,
                                int, int, HWND parent, HMENU, HINSTANCE,
                                LPVOID) {
  Check(parent == HWND_MESSAGE, "receiver stays message-only");
  ++state.create_window_calls;
  return state.window_fails ? nullptr : receiver_handle;
}
BOOL WINAPI FakeDestroyWindow(HWND window) {
  Check(window == receiver_handle, "only fake receiver destroyed");
  ++state.destroy_calls;
  return TRUE;
}
BOOL WINAPI FakeUnregisterClassW(LPCWSTR, HINSTANCE) {
  ++state.unregister_calls;
  return TRUE;
}
LRESULT WINAPI FakeSendMessageTimeoutW(HWND, UINT, WPARAM, LPARAM, UINT, UINT,
                                       PDWORD_PTR);

DWORD WINAPI FakeGetModuleFileNameW(HMODULE module, LPWSTR buffer, DWORD size) {
  Check(module == nullptr, "current executable requested");
  if (state.executable.empty()) {
    return 0;
  }
  if (state.executable.size() >= size) {
    return size;
  }
  std::memcpy(buffer, state.executable.c_str(),
              (state.executable.size() + 1) * sizeof(wchar_t));
  return static_cast<DWORD>(state.executable.size());
}
LSTATUS WINAPI FakeRegGetValueW(HKEY hive, LPCWSTR subkey, LPCWSTR name,
                                DWORD flags, LPDWORD, PVOID data,
                                LPDWORD bytes) {
  Check(hive == HKEY_CURRENT_USER && flags == RRF_RT_REG_SZ,
        "registry reads stay per-user and string-only");
  const auto found = state.registry.find({subkey, name == nullptr ? L"" : name});
  if (found == state.registry.end()) {
    return ERROR_FILE_NOT_FOUND;
  }
  const DWORD required =
      static_cast<DWORD>((found->second.size() + 1) * sizeof(wchar_t));
  const DWORD capacity = *bytes;
  *bytes = required;
  if (data != nullptr) {
    if (capacity < required) {
      return ERROR_MORE_DATA;
    }
    std::memcpy(data, found->second.c_str(), required);
  }
  return ERROR_SUCCESS;
}
LSTATUS WINAPI FakeRegCreateKeyExW(HKEY hive, LPCWSTR subkey, DWORD, LPWSTR,
                                   DWORD options, REGSAM access,
                                   const LPSECURITY_ATTRIBUTES attributes,
                                   PHKEY key, LPDWORD) {
  Check(hive == HKEY_CURRENT_USER && options == REG_OPTION_NON_VOLATILE &&
            access == KEY_SET_VALUE && attributes == nullptr,
        "registry write scope and permissions unchanged");
  if (++state.registry_create_calls == state.fail_create_at) {
    return ERROR_ACCESS_DENIED;
  }
  state.opened_subkey = subkey;
  *key = key_handle;
  return ERROR_SUCCESS;
}
LSTATUS WINAPI FakeRegSetValueExW(HKEY key, LPCWSTR name, DWORD, DWORD type,
                                 const BYTE* data, DWORD bytes) {
  Check(key == key_handle && type == REG_SZ, "only fake string key written");
  if (++state.registry_set_calls == state.fail_set_at) {
    return ERROR_ACCESS_DENIED;
  }
  Check(bytes >= sizeof(wchar_t) && bytes % sizeof(wchar_t) == 0,
        "registry payload is terminated UTF-16");
  const auto* text = reinterpret_cast<const wchar_t*>(data);
  Check(text[bytes / sizeof(wchar_t) - 1] == L'\0', "registry terminator");
  state.registry[{state.opened_subkey, name == nullptr ? L"" : name}] = text;
  return ERROR_SUCCESS;
}
LSTATUS WINAPI FakeRegCloseKey(HKEY key) {
  Check(key == key_handle, "only fake registry key closed");
  ++state.registry_close_calls;
  return ERROR_SUCCESS;
}

bool DispatchDeepLink(const std::string& link) {
  ++state.dispatch_calls;
  state.dispatched_link = link;
  return state.dispatch_accepts && !link.empty();
}
std::string Utf8FromUtf16(const wchar_t* text) {
  if (state.conversion_fails) {
    return {};
  }
  std::string result;
  while (*text != L'\0') {
    Check(*text <= 127, "test conversion receives synthetic ASCII only");
    result.push_back(static_cast<char>(*text++));
  }
  return result;
}

#define CreateMutexW FakeCreateMutexW
#define GetLastError FakeGetLastError
#define CloseHandle FakeCloseHandle
#define FindWindowExW FakeFindWindowExW
#define Sleep FakeSleep
#define IsWindow FakeIsWindow
#define IsIconic FakeIsIconic
#define ShowWindow FakeShowWindow
#define SetForegroundWindow FakeSetForegroundWindow
#define GetWindowThreadProcessId FakeGetWindowThreadProcessId
#define AllowSetForegroundWindow FakeAllowSetForegroundWindow
#define DefWindowProcW FakeDefWindowProcW
#define GetModuleHandleW FakeGetModuleHandleW
#define RegisterClassW FakeRegisterClassW
#define CreateWindowExW FakeCreateWindowExW
#define DestroyWindow FakeDestroyWindow
#define UnregisterClassW FakeUnregisterClassW
#define SendMessageTimeoutW FakeSendMessageTimeoutW
#define GetModuleFileNameW FakeGetModuleFileNameW
#define RegGetValueW FakeRegGetValueW
#define RegCreateKeyExW FakeRegCreateKeyExW
#define RegSetValueExW FakeRegSetValueExW
#define RegCloseKey FakeRegCloseKey

#include "../single_instance.cpp"
#include "../protocol_registration.cpp"

#undef CreateMutexW
#undef GetLastError
#undef CloseHandle
#undef FindWindowExW
#undef Sleep
#undef IsWindow
#undef IsIconic
#undef ShowWindow
#undef SetForegroundWindow
#undef GetWindowThreadProcessId
#undef AllowSetForegroundWindow
#undef DefWindowProcW
#undef GetModuleHandleW
#undef RegisterClassW
#undef CreateWindowExW
#undef DestroyWindow
#undef UnregisterClassW
#undef SendMessageTimeoutW
#undef GetModuleFileNameW
#undef RegGetValueW
#undef RegCreateKeyExW
#undef RegSetValueExW
#undef RegCloseKey

LRESULT WINAPI FakeSendMessageTimeoutW(HWND window, UINT message, WPARAM wparam,
                                       LPARAM lparam, UINT flags, UINT timeout,
                                       PDWORD_PTR result) {
  Check(window == receiver_handle && message == WM_COPYDATA,
        "forward uses receiver COPYDATA");
  Check(flags == (SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT) && timeout == 5000,
        "send remains bounded and detects receiver exit");
  ++state.send_calls;
  if (!state.transport_succeeds) {
    *result = TRUE;
    return 0;
  }
  *result = state.deliver_to_receiver
                ? static_cast<DWORD_PTR>(ReceiverWndProc(window, message,
                                                        wparam, lparam))
                : state.acknowledgement;
  return 1;
}

namespace {

void Reset() {
  state = State{};
  g_mutex = nullptr;
  g_receiver = nullptr;
  g_main_window = main_handle;
}

COPYDATASTRUCT Payload(const std::wstring& link) {
  COPYDATASTRUCT payload{};
  payload.dwData = kDeepLinkPayloadId;
  payload.cbData = static_cast<DWORD>((link.size() + 1) * sizeof(wchar_t));
  payload.lpData = const_cast<wchar_t*>(link.c_str());
  return payload;
}

LRESULT Receive(COPYDATASTRUCT* payload) {
  return ReceiverWndProc(receiver_handle, WM_COPYDATA, 0,
                         reinterpret_cast<LPARAM>(payload));
}

void TestPayloads() {
  Reset();
  const std::wstring valid = L"ErEbRuSvPn://callback?test=synthetic";
  auto payload = Payload(valid);
  std::wstring parsed;
  Check(LinkFromPayload(payload, &parsed) && parsed == valid,
        "scheme recognition is case insensitive and preserves payload");
  Check(Receive(&payload) == TRUE && state.dispatch_calls == 1 &&
            state.dispatched_link == "ErEbRuSvPn://callback?test=synthetic",
        "valid callback reaches dispatcher");

  Reset();
  Check(Receive(nullptr) == FALSE, "null COPYDATA rejected");
  payload.dwData = 0;
  Check(Receive(&payload) == FALSE, "wrong payload tag rejected");
  payload = Payload(valid);
  payload.lpData = nullptr;
  Check(Receive(&payload) == FALSE, "null payload data rejected");
  payload = Payload(valid);
  payload.cbData = 0;
  Check(Receive(&payload) == FALSE, "zero byte payload rejected");
  payload.cbData = 1;
  Check(Receive(&payload) == FALSE, "undersized payload rejected");
  payload.cbData = 3;
  Check(Receive(&payload) == FALSE, "odd byte count rejected");
  payload.cbData = 32769 * sizeof(wchar_t);
  Check(Receive(&payload) == FALSE, "oversized payload rejected before reading");
  payload = Payload(valid);
  payload.cbData -= static_cast<DWORD>(sizeof(wchar_t));
  Check(Receive(&payload) == FALSE, "missing terminator rejected");
  std::wstring embedded = valid;
  embedded.push_back(L'\0');
  embedded += L"trailing";
  payload = Payload(embedded);
  Check(Receive(&payload) == FALSE, "embedded terminator rejected");
  const std::wstring wrong_scheme = L"https://example.invalid/test";
  payload = Payload(wrong_scheme);
  Check(Receive(&payload) == FALSE, "other scheme rejected");
  Check(state.dispatch_calls == 0 && state.show_calls == 0,
        "malformed callbacks neither dispatch nor activate");

  Reset();
  const std::wstring empty;
  payload = Payload(empty);
  Check(Receive(&payload) == TRUE && state.dispatch_calls == 0 &&
            state.show_calls == 1 && state.show_command == SW_SHOW &&
            state.foreground_calls == 1,
        "empty activation surfaces window without dispatch");
  state.iconic = true;
  Check(Receive(&payload) == TRUE && state.show_command == SW_RESTORE,
        "minimized window restored");
  state.main_valid = false;
  Check(Receive(&payload) == FALSE, "missing main window rejects activation");

  Reset();
  payload = Payload(valid);
  state.dispatch_accepts = false;
  Check(Receive(&payload) == FALSE, "dispatch rejection is not acknowledged");
  state.dispatch_accepts = true;
  state.conversion_fails = true;
  Check(Receive(&payload) == FALSE, "conversion failure is not acknowledged");
}

void TestForwarding() {
  const std::wstring link = L"erebrusvpn://callback?test=synthetic";
  Reset();
  Check(ForwardToPrimaryInstance(link) && state.send_calls == 1 &&
            state.dispatch_calls == 1,
        "forward succeeds with actual receiver acknowledgement");
  Reset();
  state.dispatch_accepts = false;
  Check(!ForwardToPrimaryInstance(link) && state.send_calls == 1,
        "receiver rejection fails forwarding without retry");
  Reset();
  state.transport_succeeds = false;
  Check(!ForwardToPrimaryInstance(link) && state.send_calls == 1,
        "transport failure fails even with nonzero result and is not retried");
  for (DWORD_PTR acknowledgement : {DWORD_PTR{0}, DWORD_PTR{2}, DWORD_PTR{1}}) {
    Reset();
    state.deliver_to_receiver = false;
    state.acknowledgement = acknowledgement;
    Check(ForwardToPrimaryInstance(link) == (acknowledgement == TRUE),
          "only explicit TRUE acknowledgement is successful");
  }
  Reset();
  state.absent_polls = 3;
  Check(ForwardToPrimaryInstance(link) && state.find_calls == 4 &&
            state.sleep_calls == 3 && state.send_calls == 1,
        "cold-start receiver discovery retries before sending once");
  Reset();
  state.absent_polls = 100;
  Check(!ForwardToPrimaryInstance(link) && state.find_calls == 40 &&
            state.sleep_calls == 40 && state.send_calls == 0,
        "missing receiver fails after bounded discovery");
  Reset();
  Check(!ForwardToPrimaryInstance(std::wstring(32768, L'x')),
        "oversized outgoing link rejected");
  Check(!ForwardToPrimaryInstance(std::wstring(L"a\0b", 3)) &&
            state.find_calls == 0 && state.send_calls == 0,
        "embedded-NUL outgoing link rejected before lookup");
  Check(ForwardToPrimaryInstance(L"") && state.dispatch_calls == 0 &&
            state.show_calls == 1,
        "empty launch activates through forwarding path");
}

void TestMutexAndReceiver() {
  Reset();
  state.mutex_fails = true;
  state.error = ERROR_ACCESS_DENIED;
  Check(!AcquireSingleInstanceLock() && g_mutex == nullptr,
        "mutex creation failure never grants primary ownership");
  Reset();
  state.error = ERROR_ALREADY_EXISTS;
  Check(!AcquireSingleInstanceLock() && g_mutex == nullptr &&
            state.close_calls == 1,
        "existing mutex never grants second ownership and closes handle");
  Reset();
  Check(AcquireSingleInstanceLock() && g_mutex == mutex_handle,
        "new mutex grants primary ownership");
  Check(CreateDeepLinkReceiver(main_handle), "receiver creation succeeds");
  Check(CreateDeepLinkReceiver(main_handle) && state.create_window_calls == 1,
        "receiver creation is idempotent");
  ReleaseSingleInstance();
  Check(g_mutex == nullptr && g_receiver == nullptr && g_main_window == nullptr &&
            state.close_calls == 1 && state.destroy_calls == 1 &&
            state.unregister_calls == 1,
        "primary resources released");
  ReleaseSingleInstance();
  Check(state.close_calls == 1 && state.destroy_calls == 1,
        "cleanup is idempotent");
  Reset();
  Check(!CreateDeepLinkReceiver(nullptr) && state.create_window_calls == 0,
        "receiver requires valid main window");
  Reset();
  state.register_fails = true;
  state.error = ERROR_ACCESS_DENIED;
  Check(!CreateDeepLinkReceiver(main_handle) && state.create_window_calls == 0,
        "class registration failure reported");
  state.error = ERROR_CLASS_ALREADY_EXISTS;
  Check(CreateDeepLinkReceiver(main_handle), "existing receiver class accepted");
  Reset();
  state.window_fails = true;
  Check(!CreateDeepLinkReceiver(main_handle) && g_receiver == nullptr,
        "window creation failure reported");
}

void TestRegistration() {
  Reset();
  Check(EnsureProtocolRegistered(), "missing registration repaired");
  Check(state.registry_create_calls == 4 && state.registry_set_calls == 4 &&
            state.registry_close_calls == 4,
        "all four registration writes checked and handles closed");
  Check(state.registry[{kCommandKey, L""}] ==
            L"\"C:\\Test App\\erebrus.exe\" \"%1\"",
        "executable and callback argument remain quoted");
  const auto marker = state.registry.find({kProtocolKey, kUrlProtocolValue});
  Check(marker != state.registry.end() && marker->second.empty(),
        "URL Protocol marker exists and is empty");
  Check(EnsureProtocolRegistered() && state.registry_create_calls == 4 &&
            state.registry_set_calls == 4,
        "correct registration fast path performs no writes");
  state.registry.erase({kProtocolKey, kUrlProtocolValue});
  Check(EnsureProtocolRegistered() && state.registry_set_calls == 8,
        "missing protocol marker repaired despite matching command");

  for (int failure = 1; failure <= 4; ++failure) {
    Reset();
    state.fail_create_at = failure;
    Check(!EnsureProtocolRegistered() &&
              state.registry_create_calls == failure &&
              state.registry_set_calls == failure - 1 &&
              state.registry_close_calls == failure - 1,
          "each registry key creation failure is reported and short-circuits");
    Reset();
    state.fail_set_at = failure;
    Check(!EnsureProtocolRegistered() &&
              state.registry_set_calls == failure &&
              state.registry_close_calls == failure,
          "each registry value write failure is reported and key is closed");
  }
  Reset();
  state.executable.clear();
  Check(!EnsureProtocolRegistered() && state.registry_create_calls == 0,
        "missing executable path fails before registry writes");
  Reset();
  state.executable = L"C:\\" + std::wstring(300, L'x') + L"\\erebrus.exe";
  Check(EnsureProtocolRegistered(), "long executable path buffer grows");
}

}

int main() {
  TestPayloads();
  TestForwarding();
  TestMutexAndReceiver();
  TestRegistration();
  std::printf("PASS: Windows native deep-link regression checks (%d)\n", checks);
  return EXIT_SUCCESS;
}
