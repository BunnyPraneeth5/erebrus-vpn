#include "browser_proxy_plugin.h"

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>
#include <WebView2.h>

#include <memory>

namespace {

constexpr wchar_t kBrowserArguments[] =
    L"--proxy-server=http://127.0.0.1:10808 "
    L"--proxy-bypass-list=<-loopback> "
    L"--force-webrtc-ip-handling-policy=disable_non_proxied_udp --disable-quic";

}

bool ConfigureBrowserProxyEnvironment() {
  LPWSTR version = nullptr;
  const HRESULT result = GetAvailableCoreWebView2BrowserVersionString(nullptr, &version);
  const bool available = SUCCEEDED(result) && version != nullptr && version[0] != L'\0';
  CoTaskMemFree(version);
  return available && ::SetEnvironmentVariableW(
      L"WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", kBrowserArguments) != FALSE;
}

void RegisterBrowserProxyPlugin(flutter::FlutterViewController* controller) {
  auto configured = std::make_shared<bool>(false);
  flutter::MethodChannel<flutter::EncodableValue> channel(
      controller->engine()->messenger(), "dev.erebrus/browser",
      &flutter::StandardMethodCodec::GetInstance());
  channel.SetMethodCallHandler(
      [configured](const auto& call, auto result) {
        if (call.method_name() != "configure" &&
            call.method_name() != "secureViews") {
          result->NotImplemented();
          return;
        }
        if (call.arguments() != nullptr && !call.arguments()->IsNull()) {
          result->Error("invalid_arguments", "This method accepts no arguments.");
          return;
        }
        if (call.method_name() == "configure") {
          *configured = false;
          if (!ConfigureBrowserProxyEnvironment()) {
            result->Error("browser_proxy_configuration_failed",
                          "Could not initialize the secure browser. Check that Microsoft Edge WebView2 Runtime is installed.");
            return;
          }
          *configured = true;
        }
        result->Success(flutter::EncodableValue(*configured));
      });
}
