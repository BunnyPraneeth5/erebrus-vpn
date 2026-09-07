#include "url_scheme_registration.h"

#include <cstring>

static void test_commandline_roundtrip(gconstpointer data) {
  const gchar* executable = static_cast<const gchar*>(data);
  g_autofree gchar* commandline = erebrus_url_scheme_commandline(executable);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      commandline, "Erebrus VPN test", G_APP_INFO_CREATE_SUPPORTS_URIS, &error);
  g_assert_no_error(error);
  g_assert_nonnull(app_info);
  g_assert_null(g_app_info_get_id(app_info));
  g_assert_true(erebrus_url_scheme_matches(app_info, executable));
  g_assert_false(erebrus_url_scheme_matches(app_info, "/different/erebrus_vpn"));

  g_autoptr(GString) expanded = g_string_new(nullptr);
  for (const gchar* p = commandline; *p != '\0'; ++p) {
    if (*p == '%') {
      g_assert_cmpint(p[1], ==, '%');
      ++p;
    }
    g_string_append_c(expanded, *p);
  }
  gint argc = 0;
  g_auto(GStrv) argv = nullptr;
  g_assert_true(g_shell_parse_argv(expanded->str, &argc, &argv, &error));
  g_assert_no_error(error);
  if (strchr(executable, '%') != nullptr) {
    g_assert_cmpint(argc, ==, 5);
    g_assert_cmpstr(argv[0], ==, "/bin/sh");
    g_assert_cmpstr(argv[1], ==, "-c");
    g_assert_cmpstr(argv[2], ==, "exec \"$@\"");
    g_assert_cmpstr(argv[3], ==, "erebrus-vpn");
    g_assert_cmpstr(argv[4], ==, executable);
  } else {
    g_assert_cmpint(argc, ==, 1);
    g_assert_cmpstr(argv[0], ==, executable);
  }
}

static void test_reject_non_uri_handler() {
  const gchar* executable = "/opt/erebrus_vpn";
  g_autofree gchar* commandline = erebrus_url_scheme_commandline(executable);
  g_autoptr(GError) error = nullptr;
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      commandline, "Erebrus VPN test", G_APP_INFO_CREATE_NONE, &error);
  g_assert_no_error(error);
  g_assert_nonnull(app_info);
  g_assert_false(erebrus_url_scheme_matches(app_info, executable));
  g_assert_false(erebrus_url_scheme_matches(nullptr, executable));
}

static void test_reject_malformed_commandline() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      "'unterminated", "Erebrus VPN test", G_APP_INFO_CREATE_SUPPORTS_URIS,
      &error);
  g_assert_false(erebrus_url_scheme_matches(app_info, "/opt/erebrus_vpn"));
}

static void test_reject_other_wrapper() {
  g_autoptr(GError) error = nullptr;
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      "/bin/sh -c 'echo \"$@\"' erebrus-vpn '/opt/erebrus_vpn'",
      "Erebrus VPN test", G_APP_INFO_CREATE_SUPPORTS_URIS, &error);
  g_assert_no_error(error);
  g_assert_nonnull(app_info);
  g_assert_false(erebrus_url_scheme_matches(app_info, "/opt/erebrus_vpn"));
}

static void test_match_resolved_executable() {
  g_autoptr(GError) error = nullptr;
  g_autofree gchar* executable = g_file_read_link("/proc/self/exe", &error);
  g_assert_no_error(error);
  g_assert_nonnull(executable);
  g_autoptr(GAppInfo) app_info = g_app_info_create_from_commandline(
      "'/proc/self/exe'", "Erebrus VPN test", G_APP_INFO_CREATE_SUPPORTS_URIS,
      &error);
  g_assert_no_error(error);
  g_assert_nonnull(app_info);
  g_assert_true(erebrus_url_scheme_matches(app_info, executable));
}

int main(int argc, char** argv) {
  g_test_init(&argc, &argv, nullptr);
  g_test_add_data_func("/url-scheme/quote-spaces",
                       "/opt/Erebrus VPN/erebrus_vpn",
                       test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-shell-characters",
                       "/tmp/Erebrus's \"VPN\"/$HOME;$(false)&`false`/erebrus\\vpn",
                       test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-percent",
                       "/tmp/Erebrus%20/erebrus_vpn",
                       test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-field-codes",
                       "/tmp/Erebrus%u%%'\"$/erebrus_vpn",
                       test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-unicode",
                       "/tmp/Erébrus/erebrus_vpn", test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-control-characters",
                       "/tmp/line\nbreak\tvpn/erebrus_vpn",
                       test_commandline_roundtrip);
  g_test_add_data_func("/url-scheme/quote-equals",
                       "/tmp/path=assignment/erebrus_vpn",
                       test_commandline_roundtrip);
  g_test_add_func("/url-scheme/reject-non-uri-handler", test_reject_non_uri_handler);
  g_test_add_func("/url-scheme/reject-malformed", test_reject_malformed_commandline);
  g_test_add_func("/url-scheme/reject-other-wrapper", test_reject_other_wrapper);
  g_test_add_func("/url-scheme/match-resolved", test_match_resolved_executable);
  return g_test_run();
}
