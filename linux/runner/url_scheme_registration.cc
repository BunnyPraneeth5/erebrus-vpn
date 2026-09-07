#include "url_scheme_registration.h"

#include <cstdlib>
#include <cstring>

gchar* erebrus_url_scheme_commandline(const gchar* executable) {
  g_return_val_if_fail(executable != nullptr, nullptr);
  g_autoptr(GString) escaped = g_string_new(nullptr);
  for (const gchar* p = executable; *p != '\0'; ++p) {
    if (*p == '%') {
      g_string_append_c(escaped, '%');
    }
    g_string_append_c(escaped, *p);
  }
  g_autofree gchar* quoted = g_shell_quote(escaped->str);
  if (strchr(executable, '%') != nullptr) {
    return g_strconcat("/bin/sh -c 'exec \"$@\"' erebrus-vpn ", quoted, nullptr);
  }
  return g_steal_pointer(&quoted);
}

gboolean erebrus_url_scheme_matches(GAppInfo* app_info,
                                    const gchar* executable) {
  if (app_info == nullptr || executable == nullptr ||
      !g_app_info_supports_uris(app_info)) {
    return FALSE;
  }
  const gchar* commandline = g_app_info_get_commandline(app_info);
  gint argc = 0;
  g_auto(GStrv) argv = nullptr;
  if (commandline == nullptr ||
      !g_shell_parse_argv(commandline, &argc, &argv, nullptr) || argc < 2) {
    return FALSE;
  }
  gint executable_index = 0;
  if (argc >= 6 && g_strcmp0(argv[0], "/bin/sh") == 0 &&
      g_strcmp0(argv[1], "-c") == 0 &&
      g_strcmp0(argv[2], "exec \"$@\"") == 0 &&
      g_strcmp0(argv[3], "erebrus-vpn") == 0) {
    executable_index = 4;
  }
  gboolean forwards_uri = FALSE;
  for (gint i = executable_index + 1; i < argc; ++i) {
    if (g_strcmp0(argv[i], "%u") == 0 || g_strcmp0(argv[i], "%U") == 0) {
      forwards_uri = TRUE;
    }
  }
  if (!forwards_uri) {
    return FALSE;
  }
  g_autoptr(GString) decoded = g_string_new(nullptr);
  for (const gchar* p = argv[executable_index]; *p != '\0'; ++p) {
    if (*p == '%') {
      if (p[1] != '%') {
        return FALSE;
      }
      ++p;
    }
    g_string_append_c(decoded, *p);
  }
  g_autofree gchar* candidate = g_path_is_absolute(decoded->str)
                                   ? g_strdup(decoded->str)
                                   : g_find_program_in_path(decoded->str);
  if (candidate == nullptr) {
    return FALSE;
  }
  if (g_strcmp0(candidate, executable) == 0) {
    return TRUE;
  }
  g_autofree gchar* resolved_candidate = realpath(candidate, nullptr);
  g_autofree gchar* resolved_executable = realpath(executable, nullptr);
  return resolved_candidate != nullptr && resolved_executable != nullptr &&
         g_strcmp0(resolved_candidate, resolved_executable) == 0;
}

gboolean erebrus_register_url_scheme(GError** error) {
  g_return_val_if_fail(error == nullptr || *error == nullptr, FALSE);
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", error);
  if (executable == nullptr) {
    return FALSE;
  }
  if (!g_path_is_absolute(executable) ||
      !g_file_test(executable, G_FILE_TEST_IS_REGULAR) ||
      !g_file_test(executable, G_FILE_TEST_IS_EXECUTABLE)) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_NOT_FOUND,
                        "The running executable is not available for callbacks");
    return FALSE;
  }
  g_autoptr(GAppInfo) current =
      g_app_info_get_default_for_uri_scheme("erebrusvpn");
  if (erebrus_url_scheme_matches(current, executable)) {
    return TRUE;
  }
  g_autofree gchar* commandline = erebrus_url_scheme_commandline(executable);
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      commandline, "Erebrus VPN", G_APP_INFO_CREATE_SUPPORTS_URIS, error);
  if (app_info == nullptr) {
    return FALSE;
  }
  if (!g_app_info_set_as_default_for_type(
          app_info, "x-scheme-handler/erebrusvpn", error)) {
    return FALSE;
  }
  g_autoptr(GAppInfo) registered =
      g_app_info_get_default_for_uri_scheme("erebrusvpn");
  if (!erebrus_url_scheme_matches(registered, executable)) {
    g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_FAILED,
                        "The desktop did not select the callback handler");
    return FALSE;
  }
  return TRUE;
}
