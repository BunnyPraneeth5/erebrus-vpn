#ifndef RUNNER_BROWSER_PROXY_PLUGIN_H_
#define RUNNER_BROWSER_PROXY_PLUGIN_H_

#include <flutter/flutter_view_controller.h>

bool ConfigureBrowserProxyEnvironment();
void RegisterBrowserProxyPlugin(flutter::FlutterViewController* controller);

#endif
