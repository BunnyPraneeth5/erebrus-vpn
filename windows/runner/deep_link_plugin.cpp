#include "deep_link_plugin.h"

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/event_stream_handler.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

constexpr char kEventsChannel[] = "com.erebrus.vpn/events";
constexpr char kMethodsChannel[] = "com.erebrus.vpn/methods";

// Counterpart of LinkStreamHandler in ios/Runner/AppDelegate.swift and
// macos/Runner/AppDelegate.swift: emits links while Dart is listening and
// buffers them while it is not.
class LinkStreamHandler
    : public flutter::StreamHandler<flutter::EncodableValue> {
 public:
  void Emit(const std::string& link) {
    if (sink_ == nullptr) {
      queued_links_.push_back(link);
      return;
    }
    sink_->Success(flutter::EncodableValue(link));
  }

 protected:
  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnListenInternal(
      const flutter::EncodableValue*,
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
      override {
    sink_ = std::move(events);
    for (const std::string& link : queued_links_) {
      sink_->Success(flutter::EncodableValue(link));
    }
    queued_links_.clear();
    return nullptr;
  }

  std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>>
  OnCancelInternal(const flutter::EncodableValue*) override {
    sink_ = nullptr;
    return nullptr;
  }

 private:
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;
  std::vector<std::string> queued_links_;
};

// Owned by the engine's messenger once SetStreamHandler moves it there — the
// EventChannel explicitly does not unregister the handler on destruction — so
// this raw pointer stays valid for the life of the engine. Same ownership shape
// as RegisterSingboxPlugin.
LinkStreamHandler* g_link_handler = nullptr;

// The link this process was launched with.
//
// Kept separate from the stream handler's queue on purpose. Dart attaches the
// event listener early, in main(), but binds the auth controller much later
// (`DeepLinkHandler.bind` immediately before `checkInitialLink` in
// WalletAuthController.initDesktopAuth), so draining this at OnListen would
// hand the link over while `_auth` is still null and it would be logged and
// dropped. Waiting for the `initialLink` call is what Apple does, and it is
// the only ordering that survives that bind.
std::string g_pending_initial_link;

}  // namespace

void SetPendingInitialLink(const std::string& link) {
  g_pending_initial_link = link;
}

bool DispatchDeepLink(const std::string& link) {
  if (g_link_handler == nullptr || link.empty()) {
    return false;
  }
  g_link_handler->Emit(link);
  return true;
}

void RegisterDeepLinkPlugin(flutter::FlutterViewController* controller) {
  auto* messenger = controller->engine()->messenger();

  auto handler = std::make_unique<LinkStreamHandler>();
  g_link_handler = handler.get();

  auto events = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      messenger, kEventsChannel, &flutter::StandardMethodCodec::GetInstance());
  events->SetStreamHandler(std::move(handler));

  auto methods =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, kMethodsChannel,
          &flutter::StandardMethodCodec::GetInstance());
  methods->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "initialLink") {
      // Push the launch link through the event channel, then answer null —
      // the link travels over the stream, never as this call's return value.
      if (!g_pending_initial_link.empty()) {
        if (!DispatchDeepLink(g_pending_initial_link)) {
          result->Error("deep_link_unavailable",
                        "The sign-in link handler is not ready. Please retry.");
          return;
        }
        g_pending_initial_link.clear();
      }
      result->Success();
      return;
    }
    result->NotImplemented();
  });
}
