#include "single_instance.h"

#include <string>

#include "deep_link_plugin.h"
#include "utils.h"

namespace {

// `Local\` scopes the mutex to this user's session. Never `Global\`, which
// needs extra privileges and is a genuine red flag to endpoint scanners.
constexpr wchar_t kMutexName[] = L"Local\\ErebrusVpnSingleInstance";

// A class name of our own keeps the lookup unambiguous. The runner's own window
// class is the Flutter template default, FLUTTER_RUNNER_WIN32_WINDOW, which
// every Flutter Windows app on the machine shares — matching on that could hand
// our link to an unrelated app's window.
constexpr wchar_t kReceiverClassName[] = L"ErebrusVpnDeepLinkReceiver";
constexpr wchar_t kReceiverWindowName[] = L"Erebrus VPN Deep Link Receiver";

// Tags our payload so an unrelated WM_COPYDATA is ignored. 'EREV'.
constexpr ULONG_PTR kDeepLinkPayloadId = 0x45524556;

// The primary creates its receiver only once the main window exists, so a link
// clicked during a cold start needs a short grace period.
constexpr int kForwardAttempts = 40;
constexpr DWORD kForwardRetryDelayMs = 100;
constexpr DWORD kForwardTimeoutMs = 5000;

HANDLE g_mutex = nullptr;
HWND g_receiver = nullptr;
HWND g_main_window = nullptr;

HWND FindReceiverWindow() {
  // Message-only windows are not top-level, so the parent must be spelled out
  // as HWND_MESSAGE. The window name is left null: the class name alone is
  // unique to us, and matching on a title would depend on GetWindowText across
  // a process boundary.
  return ::FindWindowExW(HWND_MESSAGE, nullptr, kReceiverClassName, nullptr);
}

// Never trust the sender's byte count — read at most what it declared and stop
// at the first terminator (CWE-126, same care as Utf8FromUtf16 in utils.cpp).
bool LinkFromPayload(const COPYDATASTRUCT& payload, std::wstring* link) {
  if (payload.lpData == nullptr || payload.cbData < sizeof(wchar_t) ||
      payload.cbData % sizeof(wchar_t) != 0 ||
      payload.cbData > 32768 * sizeof(wchar_t)) {
    return false;
  }
  const auto* data = static_cast<const wchar_t*>(payload.lpData);
  const size_t count = payload.cbData / sizeof(wchar_t);
  const size_t length = ::wcsnlen(data, count);
  if (length != count - 1) {
    return false;
  }
  link->assign(data, length);
  constexpr wchar_t kPrefix[] = L"erebrusvpn://";
  return link->empty() ||
         _wcsnicmp(link->c_str(), kPrefix, ::wcslen(kPrefix)) == 0;
}

// Mirrors showMainWindow in macos/Runner/AppDelegate.swift. Closing the window
// hides it rather than destroying it — desktop_shell.dart pairs
// `windowManager.setPreventClose(true)` with `hide()` to minimize to tray — so a
// forwarded link has to unhide and re-focus that same window.
void SurfaceMainWindow() {
  if (g_main_window == nullptr) {
    return;
  }
  ::ShowWindow(g_main_window, ::IsIconic(g_main_window) ? SW_RESTORE : SW_SHOW);
  ::SetForegroundWindow(g_main_window);
}

LRESULT CALLBACK ReceiverWndProc(HWND window,
                                 UINT message,
                                 WPARAM wparam,
                                 LPARAM lparam) {
  if (message == WM_COPYDATA) {
    const auto* payload = reinterpret_cast<const COPYDATASTRUCT*>(lparam);
    if (payload == nullptr || payload->dwData != kDeepLinkPayloadId) {
      return FALSE;
    }
    std::wstring link;
    if (!::IsWindow(g_main_window) || !LinkFromPayload(*payload, &link)) {
      return FALSE;
    }
    SurfaceMainWindow();
    // Runs on the platform thread, which is where the event sink must be
    // touched — one of the reasons WM_COPYDATA is preferred over a pipe here.
    return link.empty() || DispatchDeepLink(Utf8FromUtf16(link.c_str()))
               ? TRUE
               : FALSE;
  }
  return ::DefWindowProcW(window, message, wparam, lparam);
}

}  // namespace

bool AcquireSingleInstanceLock() {
  g_mutex = ::CreateMutexW(nullptr, TRUE, kMutexName);
  if (g_mutex == nullptr) {
    // Fail closed: an unavailable lock must never allow a second tunnel owner.
    return false;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(g_mutex);
    g_mutex = nullptr;
    return false;
  }
  return true;
}

bool ForwardToPrimaryInstance(const std::wstring& link) {
  if (link.size() >= 32768 || link.find(L'\0') != std::wstring::npos) {
    return false;
  }
  HWND target = nullptr;
  for (int attempt = 0; attempt < kForwardAttempts; ++attempt) {
    target = FindReceiverWindow();
    if (target != nullptr) {
      break;
    }
    ::Sleep(kForwardRetryDelayMs);
  }
  if (target == nullptr) {
    return false;
  }

  // Let the primary take the foreground. This is a window property lookup, not
  // process enumeration — no handle to the other process is ever opened.
  DWORD target_pid = 0;
  if (::GetWindowThreadProcessId(target, &target_pid) != 0) {
    ::AllowSetForegroundWindow(target_pid);
  }

  COPYDATASTRUCT payload{};
  payload.dwData = kDeepLinkPayloadId;
  payload.cbData = static_cast<DWORD>((link.size() + 1) * sizeof(wchar_t));
  payload.lpData = const_cast<wchar_t*>(link.c_str());

  // SendMessageTimeout, not PostMessage: WM_COPYDATA requires the buffer to
  // stay valid until the receiver returns, and this process exits immediately
  // afterwards. The timeout keeps a wedged primary from hanging us.
  DWORD_PTR send_result = 0;
  return ::SendMessageTimeoutW(target, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&payload),
                               SMTO_ABORTIFHUNG | SMTO_ERRORONEXIT,
                               kForwardTimeoutMs, &send_result) != 0 &&
         send_result == TRUE;
}

bool CreateDeepLinkReceiver(HWND main_window) {
  if (g_receiver != nullptr) {
    return true;
  }
  if (!::IsWindow(main_window)) {
    return false;
  }
  g_main_window = main_window;

  WNDCLASSW window_class{};
  window_class.lpfnWndProc = ReceiverWndProc;
  window_class.hInstance = ::GetModuleHandleW(nullptr);
  window_class.lpszClassName = kReceiverClassName;
  if (::RegisterClassW(&window_class) == 0 &&
      ::GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
    g_main_window = nullptr;
    return false;
  }

  // HWND_MESSAGE: no surface, no taskbar or Alt-Tab presence, no paint cycle —
  // it exists only to receive forwarded links.
  g_receiver =
      ::CreateWindowExW(0, kReceiverClassName, kReceiverWindowName, 0, 0, 0, 0,
                        0, HWND_MESSAGE, nullptr, window_class.hInstance,
                        nullptr);
  return g_receiver != nullptr;
}

void ReleaseSingleInstance() {
  if (g_receiver != nullptr) {
    ::DestroyWindow(g_receiver);
    g_receiver = nullptr;
    ::UnregisterClassW(kReceiverClassName, ::GetModuleHandleW(nullptr));
  }
  g_main_window = nullptr;
  if (g_mutex != nullptr) {
    ::CloseHandle(g_mutex);
    g_mutex = nullptr;
  }
}
