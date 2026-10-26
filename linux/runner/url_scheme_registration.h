#ifndef EREBRUS_URL_SCHEME_REGISTRATION_H_
#define EREBRUS_URL_SCHEME_REGISTRATION_H_

#include <gio/gio.h>

gchar* erebrus_url_scheme_commandline(const gchar* executable);
gboolean erebrus_url_scheme_matches(GAppInfo* app_info,
                                    const gchar* executable);
gboolean erebrus_register_url_scheme(GError** error);

#endif
