#ifndef RUNNER_APP_IDENTITY_H_
#define RUNNER_APP_IDENTITY_H_

// Registers the process and its Start menu shortcut under BStream Music's
// stable Windows AppUserModelID. This lets Windows resolve the app name and
// icon for taskbar and system media surfaces, including direct/portable runs.
void RegisterWindowsAppIdentity();

#endif  // RUNNER_APP_IDENTITY_H_
