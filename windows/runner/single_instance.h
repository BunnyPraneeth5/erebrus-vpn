#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_

#include <windows.h>

#include <string>

// Claims the per-user, per-session single-instance lock. Returns false when
// another instance already holds it, in which case this process should forward
// its link and exit rather than open a second window.
bool AcquireSingleInstanceLock();

// Hands |link| to the already-running instance and asks it to surface its
// window. An empty |link| just surfaces the window. Returns false when no
// running instance could be reached.
bool ForwardToPrimaryInstance(const std::wstring& link);

// Creates the hidden window that receives links forwarded by later launches.
// |main_window| is restored and focused whenever a link arrives.
bool CreateDeepLinkReceiver(HWND main_window);

// Tears down the receiver window and releases the single-instance lock.
void ReleaseSingleInstance();

#endif  // RUNNER_SINGLE_INSTANCE_H_
