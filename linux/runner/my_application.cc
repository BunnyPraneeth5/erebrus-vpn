#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "browser_proxy_plugin.h"
#include "flutter/generated_plugin_registrant.h"
#include "singbox_plugin.h"
#include "url_scheme_registration.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  gchar* pending_link;
  FlMethodChannel* link_methods;
  FlEventChannel* link_events;
  GCancellable* link_cancellable;
  gboolean link_listening;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void my_application_flush_link(MyApplication* self) {
  if (!self->link_listening || self->pending_link == nullptr) {
    return;
  }
  g_autoptr(FlValue) value = fl_value_new_string(self->pending_link);
  g_autoptr(GError) error = nullptr;
  if (fl_event_channel_send(self->link_events, value, self->link_cancellable,
                            &error)) {
    g_clear_pointer(&self->pending_link, g_free);
  } else {
    g_warning("Failed to send deep-link event");
  }
}

static void my_application_receive_link(MyApplication* self, const gchar* uri) {
  g_autofree gchar* scheme = g_uri_parse_scheme(uri);
  if (scheme == nullptr || g_ascii_strcasecmp(scheme, "erebrusvpn") != 0) {
    return;
  }
  g_free(self->pending_link);
  self->pending_link = g_strdup(uri);
  my_application_flush_link(self);
}

static void my_application_link_method(FlMethodChannel* channel,
                                       FlMethodCall* call,
                                       gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  g_autoptr(GError) error = nullptr;
  if (g_strcmp0(fl_method_call_get_name(call), "initialLink") == 0) {
    g_autoptr(FlValue) value = self->pending_link == nullptr
                                 ? fl_value_new_null()
                                 : fl_value_new_string(self->pending_link);
    g_autoptr(FlMethodResponse) response =
        FL_METHOD_RESPONSE(fl_method_success_response_new(value));
    if (fl_method_call_respond(call, response, &error)) {
      g_clear_pointer(&self->pending_link, g_free);
    } else {
      g_warning("Failed to respond to initialLink");
    }
    return;
  }
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  if (!fl_method_call_respond(call, response, &error)) {
    g_warning("Failed to respond to deep-link method");
  }
}

static FlMethodErrorResponse* my_application_link_listen(
    FlEventChannel* channel, FlValue* arguments, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  if (self->link_cancellable != nullptr) {
    g_cancellable_cancel(self->link_cancellable);
  }
  g_clear_object(&self->link_cancellable);
  self->link_cancellable = g_cancellable_new();
  self->link_listening = TRUE;
  my_application_flush_link(self);
  return nullptr;
}

static FlMethodErrorResponse* my_application_link_cancel(
    FlEventChannel* channel, FlValue* arguments, gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  self->link_listening = FALSE;
  if (self->link_cancellable != nullptr) {
    g_cancellable_cancel(self->link_cancellable);
  }
  g_clear_object(&self->link_cancellable);
  return nullptr;
}

static void my_application_clear_link_channels(MyApplication* self) {
  my_application_link_cancel(nullptr, nullptr, self);
  if (self->link_methods != nullptr) {
    fl_method_channel_set_method_call_handler(self->link_methods, nullptr,
                                              nullptr, nullptr);
  }
  if (self->link_events != nullptr) {
    fl_event_channel_set_stream_handlers(self->link_events, nullptr, nullptr,
                                         nullptr, nullptr);
  }
  g_clear_object(&self->link_methods);
  g_clear_object(&self->link_events);
}

static void my_application_register_link_channels(MyApplication* self,
                                                  FlView* view) {
  my_application_clear_link_channels(self);
  FlBinaryMessenger* messenger =
      fl_engine_get_binary_messenger(fl_view_get_engine(view));
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->link_methods = fl_method_channel_new(
      messenger, "com.erebrus.vpn/methods", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->link_methods, my_application_link_method, self, nullptr);
  self->link_events = fl_event_channel_new(
      messenger, "com.erebrus.vpn/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      self->link_events, my_application_link_listen, my_application_link_cancel,
      self, nullptr);
  g_signal_connect_object(view, "destroy",
                          G_CALLBACK(my_application_clear_link_channels), self,
                          G_CONNECT_SWAPPED);
}

static gchar* my_application_icon_path() {
  g_autofree gchar* exe = g_file_read_link("/proc/self/exe", NULL);
  if (exe == NULL) {
    return NULL;
  }
  g_autofree gchar* dir = g_path_get_dirname(exe);
  return g_build_filename(dir, "data", "icons", "app_icon.png", NULL);
}

static void my_application_apply_icon(GtkWindow* window) {
  g_autofree gchar* icon_path = my_application_icon_path();
  if (icon_path == NULL || !g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    return;
  }
  gtk_window_set_icon_from_file(window, icon_path, NULL);
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GList* windows = gtk_application_get_windows(GTK_APPLICATION(application));
  if (windows != nullptr) {
    gtk_window_present(GTK_WINDOW(windows->data));
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Erebrus VPN");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Erebrus VPN");
  }

  gtk_window_set_default_size(window, 880, 820);
  my_application_apply_icon(window);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  my_application_register_link_channels(self, view);
  register_browser_proxy_plugin(view, window);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  register_singbox_plugin(view);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);
  return FALSE;
}

static int my_application_command_line(GApplication* application,
                                       GApplicationCommandLine* command_line) {
  MyApplication* self = MY_APPLICATION(application);
  g_auto(GStrv) arguments =
      g_application_command_line_get_arguments(command_line, nullptr);
  for (gchar** argument = arguments + 1; *argument != nullptr; ++argument) {
    my_application_receive_link(self, *argument);
  }
  g_application_activate(application);
  return 0;
}

static void my_application_open(GApplication* application, GFile** files,
                                gint n_files, const gchar* hint) {
  MyApplication* self = MY_APPLICATION(application);
  for (gint i = 0; i < n_files; ++i) {
    g_autofree gchar* uri = g_file_get_uri(files[i]);
    my_application_receive_link(self, uri);
  }
  g_application_activate(application);
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);

  g_autoptr(GError) error = nullptr;
  if (!erebrus_register_url_scheme(&error)) {
    g_warning("Could not register Erebrus VPN browser callbacks for this user; "
              "desktop sign-in callbacks may not work (error domain %u, code %d)",
              error != nullptr ? error->domain : 0,
              error != nullptr ? error->code : 0);
  }

  g_autofree gchar* icon_path = my_application_icon_path();
  if (icon_path != NULL && g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    gtk_window_set_default_icon_from_file(icon_path, NULL);
  }
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  my_application_clear_link_channels(MY_APPLICATION(application));
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  my_application_clear_link_channels(self);
  g_clear_pointer(&self->pending_link, g_free);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->command_line = my_application_command_line;
  G_APPLICATION_CLASS(klass)->open = my_application_open;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  GApplicationFlags flags = static_cast<GApplicationFlags>(
      G_APPLICATION_HANDLES_OPEN | G_APPLICATION_HANDLES_COMMAND_LINE);
  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     flags, nullptr));
}
