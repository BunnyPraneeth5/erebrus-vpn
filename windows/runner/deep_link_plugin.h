#ifndef RUNNER_DEEP_LINK_PLUGIN_H_
#define RUNNER_DEEP_LINK_PLUGIN_H_

#include <flutter/flutter_view_controller.h>

#include <string>

// Registers `com.erebrus.vpn/methods` and `com.erebrus.vpn/events` — the
// channels DeepLinkHandler (lib/auth/deep_link_handler.dart) talks to.
//
// Uses stream delivery: `initialLink` flushes the link the process was
// launched with, then returns null. Dart also accepts returned initial URLs
// on other platforms; returning null here avoids delivering the same link
// through both the method response and event stream.
void RegisterDeepLinkPlugin(flutter::FlutterViewController* controller);

// Records the `erebrusvpn://` link this process was launched with. Called
// before the engine exists; delivered when Dart invokes `initialLink`.
void SetPendingInitialLink(const std::string& link);

// Sends |link| to Dart, buffering it when no listener is attached yet.
// Must be called on the platform thread.
bool DispatchDeepLink(const std::string& link);

#endif  // RUNNER_DEEP_LINK_PLUGIN_H_
