#include "../browser_proxy_plugin.h"

#include <windows.h>
#include <WebView2.h>
#include <WebView2EnvironmentOptions.h>
#include <wrl.h>

#include <cstdio>
#include <cwchar>
#include <initializer_list>
#include <memory>
#include <string>

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {
struct SmokeState {
  bool done = false;
  bool passed = false;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2Controller> controller;
  ComPtr<ICoreWebView2> view;
  EventRegistrationToken navigation_token = {};
  EventRegistrationToken resource_token = {};

  bool Check(HRESULT hr, const char* operation) {
    if (FAILED(hr)) {
      std::printf("FAIL: %s (HRESULT 0x%08lX)\n", operation,
                  static_cast<unsigned long>(hr));
      done = true;
      passed = false;
    }
    return SUCCEEDED(hr);
  }
};

bool RunSmokeTest() {
  constexpr wchar_t expected[] =
      L"--proxy-server=http://127.0.0.1:10808 "
      L"--proxy-bypass-list=<-loopback> "
      L"--force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-quic";
  wchar_t actual[512] = {};
  if (!ConfigureBrowserProxyEnvironment() ||
      GetEnvironmentVariableW(L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", actual,
                              512) != std::wcslen(expected) ||
      std::wcscmp(actual, expected) != 0) {
    std::puts("FAIL: production browser arguments do not match exactly");
    return false;
  }
  for (const auto* name : {L"WEBVIEW2_USER_DATA_FOLDER",
                           L"WEBVIEW2_BROWSER_EXECUTABLE_FOLDER",
                           L"WEBVIEW2_PIPE_FOR_SCRIPT_DEBUGGER"}) {
    if (!SetEnvironmentVariableW(name, nullptr) && GetLastError() != ERROR_ENVVAR_NOT_FOUND) {
      std::puts("FAIL: could not clear process-local WebView2 override");
      return false;
    }
  }
  wchar_t temp[MAX_PATH] = {};
  wchar_t guid_text[40] = {};
  GUID guid;
  const DWORD length = GetTempPathW(MAX_PATH, temp);
  if (!length || length >= MAX_PATH || FAILED(CoCreateGuid(&guid)) ||
      !StringFromGUID2(guid, guid_text, 40)) {
    std::puts("FAIL: could not obtain unique temporary profile path");
    return false;
  }
  const std::wstring profile = std::wstring(temp) + L"erebrus-webview-smoke-" + guid_text;
  if (!CreateDirectoryW(profile.c_str(), nullptr)) {
    std::puts("FAIL: could not exclusively create temporary profile directory");
    return false;
  }
  std::printf("Temporary test profile (retained; remove only after WebView2 exits): %ls\n",
              profile.c_str());
  HWND window = CreateWindowExW(0, L"STATIC", L"Browser proxy smoke test",
                                WS_OVERLAPPED, 0, 0, 640, 480, nullptr, nullptr,
                                GetModuleHandleW(nullptr), nullptr);
  if (!window) {
    std::puts("FAIL: could not create hidden test window");
    return false;
  }
  auto state = std::make_shared<SmokeState>();
  auto options = Microsoft::WRL::Make<CoreWebView2EnvironmentOptions>();
  const ULONGLONG deadline = GetTickCount64() + 30000;
  if (state->Check(options->put_AdditionalBrowserArguments(
          L"--disable-background-networking --disable-component-update "
          L"--disable-domain-reliability --disable-sync --no-first-run"), "test options")) {
    state->Check(CreateCoreWebView2EnvironmentWithOptions(nullptr, profile.c_str(),
        options.Get(), Callback<ICoreWebView2CreateCoreWebView2EnvironmentCompletedHandler>(
        [state, window](HRESULT hr,
            ICoreWebView2Environment* environment) -> HRESULT {
          if (state->done || !state->Check(hr, "create environment")) return S_OK;
          if (!state->Check(environment ? S_OK : E_POINTER, "environment pointer")) return S_OK;
          state->environment = environment;
          LPWSTR version = nullptr;
          if (SUCCEEDED(environment->get_BrowserVersionString(&version)) && version)
            std::printf("WebView2 runtime: %ls\n", version);
          CoTaskMemFree(version);
          state->Check(environment->CreateCoreWebView2Controller(window,
              Callback<ICoreWebView2CreateCoreWebView2ControllerCompletedHandler>(
              [state](HRESULT result,
                  ICoreWebView2Controller* controller) -> HRESULT {
                if (state->done || !state->Check(result, "create controller")) return S_OK;
                if (!state->Check(controller ? S_OK : E_POINTER, "controller pointer")) return S_OK;
                state->controller = controller;
                RECT bounds = {0, 0, 640, 480};
                if (!state->Check(controller->put_Bounds(bounds), "set bounds") ||
                    !state->Check(controller->put_IsVisible(FALSE), "hide WebView2") ||
                    !state->Check(controller->get_CoreWebView2(&state->view), "get WebView2")) return S_OK;
                if (!state->Check(state->view->AddWebResourceRequestedFilter(
                        L"*", COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL), "block resource filter") ||
                    !state->Check(state->view->add_WebResourceRequested(
                        Callback<ICoreWebView2WebResourceRequestedEventHandler>(
                        [state](ICoreWebView2*, ICoreWebView2WebResourceRequestedEventArgs* args) -> HRESULT {
                          if (state->done) return E_ABORT;
                          ComPtr<ICoreWebView2WebResourceResponse> response;
                          HRESULT blocked = state->environment->CreateWebResourceResponse(
                              nullptr, 403, L"Blocked by local smoke test", L"", &response);
                          if (SUCCEEDED(blocked)) blocked = args->put_Response(response.Get());
                          state->Check(FAILED(blocked) ? blocked : E_ACCESSDENIED,
                                       "unexpected resource request (blocked)");
                          return blocked;
                        }).Get(), &state->resource_token), "register resource blocker")) return S_OK;
                if (!state->Check(state->view->add_NavigationCompleted(
                    Callback<ICoreWebView2NavigationCompletedEventHandler>(
                    [state](ICoreWebView2*, ICoreWebView2NavigationCompletedEventArgs* args) -> HRESULT {
                      if (state->done) return S_OK;
                      BOOL success = FALSE;
                      if (!state->Check(args->get_IsSuccess(&success), "navigation status") ||
                          !state->Check(success ? S_OK : E_FAIL, "local HTML navigation")) return S_OK;
                      state->Check(state->view->ExecuteScript(
                          L"document.getElementById('smoke-marker').textContent === 'local-html-ok'",
                          Callback<ICoreWebView2ExecuteScriptCompletedHandler>(
                          [state](HRESULT script_hr, LPCWSTR json) -> HRESULT {
                            if (state->done || !state->Check(script_hr, "execute script")) return S_OK;
                            state->passed = json && std::wcscmp(json, L"true") == 0;
                            state->Check(state->passed ? S_OK : E_FAIL, "DOM marker verification");
                            state->done = true;
                            return S_OK;
                          }).Get()), "start script");
                      return S_OK;
                    }).Get(), &state->navigation_token), "register navigation handler")) return S_OK;
                state->Check(state->view->NavigateToString(
                    L"<!doctype html><html><head><meta http-equiv='Content-Security-Policy' "
                    L"content=\"default-src 'none'\"></head><body>"
                    L"<div id='smoke-marker'>local-html-ok</div></body></html>"), "navigate local HTML");
                return S_OK;
              }).Get()), "start controller");
          return S_OK;
        }).Get()), "start environment");
  }
  while (!state->done && GetTickCount64() < deadline) {
    MSG message;
    if (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
      if (message.message == WM_QUIT) {
        state->Check(E_ABORT, "unexpected window quit");
        break;
      }
      TranslateMessage(&message);
      DispatchMessageW(&message);
    } else {
      MsgWaitForMultipleObjectsEx(0, nullptr, 50, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
    }
  }
  if (!state->done) state->Check(HRESULT_FROM_WIN32(WAIT_TIMEOUT), "30-second event-loop timeout");
  state->done = true;
  if (state->view) {
    state->view->remove_NavigationCompleted(state->navigation_token);
    state->view->remove_WebResourceRequested(state->resource_token);
  }
  if (state->controller) state->controller->Close();
  state->view.Reset();
  state->controller.Reset();
  state->environment.Reset();
  DestroyWindow(window);
  if (state->passed) std::puts("PASS: exact production proxy flags and local HTML DOM verified");
  return state->passed;
}
}

int main() {
  if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
    std::puts("FAIL: COM initialization");
    return 1;
  }
  const bool passed = RunSmokeTest();
  CoUninitialize();
  return passed ? 0 : 1;
}
