#include "browser_proxy_plugin.h"

#include <webkit2/webkit2.h>

namespace {

constexpr char kStateKey[] = "erebrus-browser-proxy-state";
constexpr char kProxyUri[] = "http://127.0.0.1:10808";

struct BrowserProxyState {
  FlMethodChannel* channel;
  GWeakRef window;
  gboolean configured;
};

struct SecureViewsResult {
  guint found;
  gboolean applied;
};

gboolean ApplyProxy(WebKitWebContext* context) {
  if (context == nullptr) {
    return FALSE;
  }
  WebKitWebsiteDataManager* manager =
      webkit_web_context_get_website_data_manager(context);
  if (manager == nullptr) {
    return FALSE;
  }
  WebKitNetworkProxySettings* proxy =
      webkit_network_proxy_settings_new(kProxyUri, nullptr);
  if (proxy == nullptr) {
    return FALSE;
  }
  webkit_website_data_manager_set_network_proxy_settings(
      manager, WEBKIT_NETWORK_PROXY_MODE_CUSTOM, proxy);
  webkit_network_proxy_settings_free(proxy);
  return TRUE;
}

gboolean DisableSetting(WebKitSettings* settings, const gchar* name,
                        gboolean required) {
  if (settings == nullptr) {
    return FALSE;
  }
  GParamSpec* property =
      g_object_class_find_property(G_OBJECT_GET_CLASS(settings), name);
  if (property == nullptr) {
    return !required;
  }
  if (G_PARAM_SPEC_VALUE_TYPE(property) != G_TYPE_BOOLEAN ||
      !(property->flags & G_PARAM_READABLE) ||
      !(property->flags & G_PARAM_WRITABLE) ||
      (property->flags & G_PARAM_CONSTRUCT_ONLY)) {
    return FALSE;
  }
  g_object_set(settings, name, FALSE, nullptr);
  gboolean enabled = TRUE;
  g_object_get(settings, name, &enabled, nullptr);
  return !enabled;
}

void SecureWidget(GtkWidget* widget, gpointer user_data) {
  auto* result = static_cast<SecureViewsResult*>(user_data);
  if (WEBKIT_IS_WEB_VIEW(widget)) {
    ++result->found;
    WebKitWebView* view = WEBKIT_WEB_VIEW(widget);
    if (!ApplyProxy(webkit_web_view_get_context(view))) {
      result->applied = FALSE;
    }
    WebKitSettings* settings = webkit_web_view_get_settings(view);
    if (!DisableSetting(settings, "enable-webrtc", TRUE)) {
      result->applied = FALSE;
    }
    if (!DisableSetting(settings, "enable-dns-prefetching", FALSE)) {
      result->applied = FALSE;
    }
  }
  if (GTK_IS_CONTAINER(widget)) {
    gtk_container_forall(GTK_CONTAINER(widget), SecureWidget, result);
  }
}

FlMethodResponse* HandleMethod(FlMethodCall* call, BrowserProxyState* state) {
  const gchar* method = fl_method_call_get_name(call);
  if (g_strcmp0(method, "configure") != 0 &&
      g_strcmp0(method, "secureViews") != 0) {
    return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  FlValue* arguments = fl_method_call_get_args(call);
  if (arguments != nullptr && fl_value_get_type(arguments) != FL_VALUE_TYPE_NULL) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "invalid_arguments", "This method accepts no arguments.", nullptr));
  }
  if (g_strcmp0(method, "configure") == 0) {
    state->configured = ApplyProxy(webkit_web_context_get_default());
    if (!state->configured) {
      return FL_METHOD_RESPONSE(fl_method_error_response_new(
          "browser_proxy_configuration_failed",
          "Could not configure the embedded browser proxy.", nullptr));
    }
    g_autoptr(FlValue) value = fl_value_new_bool(TRUE);
    return FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  }
  SecureViewsResult result = {0, TRUE};
  g_autoptr(GObject) window = G_OBJECT(g_weak_ref_get(&state->window));
  if (state->configured && window != nullptr && GTK_IS_WINDOW(window)) {
    SecureWidget(GTK_WIDGET(window), &result);
  }
  g_autoptr(FlValue) value =
      fl_value_new_bool(state->configured && result.found > 0 && result.applied);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(value));
}

void MethodCall(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
  auto* state = static_cast<BrowserProxyState*>(user_data);
  g_autoptr(FlMethodResponse) response = HandleMethod(call, state);
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("Failed to respond to embedded browser method");
  }
}

void FreeState(gpointer user_data) {
  auto* state = static_cast<BrowserProxyState*>(user_data);
  fl_method_channel_set_method_call_handler(state->channel, nullptr, nullptr,
                                            nullptr);
  g_clear_object(&state->channel);
  g_weak_ref_clear(&state->window);
  delete state;
}

void ViewDestroyed(GtkWidget* view, gpointer) {
  g_object_set_data(G_OBJECT(view), kStateKey, nullptr);
}

}

void register_browser_proxy_plugin(FlView* view, GtkWindow* window) {
  auto* state = new BrowserProxyState{};
  g_weak_ref_init(&state->window, G_OBJECT(window));
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  state->channel = fl_method_channel_new(
      messenger, "dev.erebrus/browser", FL_METHOD_CODEC(codec));
  g_object_set_data_full(G_OBJECT(view), kStateKey, state, FreeState);
  fl_method_channel_set_method_call_handler(state->channel, MethodCall, state,
                                            nullptr);
  g_signal_connect(view, "destroy", G_CALLBACK(ViewDestroyed), nullptr);
}
