#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>

#include "deep_link_plugin.h"
#include "flutter_window.h"
#include "protocol_registration.h"
#include "single_instance.h"
#include "utils.h"

namespace {

constexpr wchar_t kDeepLinkPrefix[] = L"erebrusvpn://";

// The shell passes a clicked `erebrusvpn://` link as a single argument, per the
// `"%1"` in the registered shell\open\command. Read here rather than from the
// Dart entrypoint arguments the template already forwards: lib/main.dart takes
// no parameters, so those are discarded, and the link has to reach Dart over
// the event channel to match every other platform.
std::wstring DeepLinkFromCommandLine() {
  int argc = 0;
  wchar_t **argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::wstring();
  }
  std::wstring link;
  const size_t prefix_length = ::wcslen(kDeepLinkPrefix);
  for (int i = 1; i < argc; i++) {
    if (_wcsnicmp(argv[i], kDeepLinkPrefix, prefix_length) == 0) {
      link = argv[i];
      break;
    }
  }
  ::LocalFree(argv);
  return link;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  const std::wstring deep_link = DeepLinkFromCommandLine();

  // Clicking a link while the app is already running starts a second process.
  // It has to hand the link to the first one and exit, or the user ends up with
  // a duplicate window and a tunnel-owning process that is no longer in front.
  if (!AcquireSingleInstanceLock()) {
    const bool forwarded = ForwardToPrimaryInstance(deep_link);
    ReleaseSingleInstance();
    if (!forwarded) {
      ::MessageBoxW(nullptr,
                    L"Erebrus VPN could not safely open this request. "
                    L"Close any running Erebrus VPN instance and try again.",
                    L"Erebrus VPN", MB_OK | MB_ICONERROR);
      return EXIT_FAILURE;
    }
    return EXIT_SUCCESS;
  }

  // Claim the scheme before the engine starts; it is a couple of registry reads
  // in the common case and Dart never needs to ask for it.
  if (!EnsureProtocolRegistered()) {
    ::MessageBoxW(nullptr,
                  L"Erebrus VPN could not register its sign-in link handler. "
                  L"The app will close. Please try again or contact support.",
                  L"Erebrus VPN", MB_OK | MB_ICONERROR);
    ReleaseSingleInstance();
    return EXIT_FAILURE;
  }

  if (!deep_link.empty()) {
    SetPendingInitialLink(Utf8FromUtf16(deep_link.c_str()));
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(880, 820);
  if (!window.Create(L"Erebrus VPN", origin, size)) {
    ::MessageBoxW(nullptr, L"Erebrus VPN could not create its main window.",
                  L"Erebrus VPN", MB_OK | MB_ICONERROR);
    window.Destroy();
    ReleaseSingleInstance();
    ::CoUninitialize();
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  // Created after the main window so a forwarded link always has a window to
  // surface. Later launches retry briefly, which covers this startup gap.
  if (!CreateDeepLinkReceiver(window.GetHandle())) {
    window.SetQuitOnClose(false);
    window.Destroy();
    ::MessageBoxW(nullptr,
                  L"Erebrus VPN could not start its sign-in link receiver. "
                  L"The app will close. Please try again.",
                  L"Erebrus VPN", MB_OK | MB_ICONERROR);
    ReleaseSingleInstance();
    ::CoUninitialize();
    return EXIT_FAILURE;
  }

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ReleaseSingleInstance();
  ::CoUninitialize();
  return EXIT_SUCCESS;
}
