#ifndef RUNNER_PROTOCOL_REGISTRATION_H_
#define RUNNER_PROTOCOL_REGISTRATION_H_

// Claims the `erebrusvpn://` URL scheme for the current user, pointing it at
// the running executable.
//
// Android and Apple register the scheme declaratively at install time
// (AndroidManifest `<data android:scheme>`, `CFBundleURLTypes`). Windows has no
// installer to do that, so the app registers itself on launch. The claim is
// read back first and left untouched when it is already correct, so a normal
// launch performs no registry writes at all.
bool EnsureProtocolRegistered();

#endif  // RUNNER_PROTOCOL_REGISTRATION_H_
