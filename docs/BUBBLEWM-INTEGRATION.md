# BubbleWM integration plan

## Status

BubbleWM is developed in its own repository. It is currently an early nested
Wayland compositor prototype with a built-in lock screen. It does not yet
provide a system login greeter, create an authenticated user session, or manage
session start and shutdown.

The desktop-enabled BubbleOS development image currently uses
`greetd`/`tuigreet` to authenticate on VT 7 and launch `bubble-desktop
session`, which starts Wayfire. BubbleOS's `tests` branch is currently
console-only. Neither path is integrated with BubbleWM yet.

## Target

BubbleWM will own the graphical login and session lifecycle for its desktop.
In BubbleOS, it is intended to replace `greetd`/`tuigreet` and Wayfire. Other
distributions should be able to package BubbleWM in place of LightDM or their
existing display manager, while keeping BubbleWM independent of distro
internals.

The managed desktop and login sessions are Wayland-only. BubbleWM will not
offer Xorg sessions. Optional XWayland support may run legacy applications
inside a Wayland session, but it is not an X11 login path.

The system-facing BubbleWM supervisor must:

- show a Wayland greeter on the active VT and list eligible local accounts;
- authenticate and validate accounts through PAM;
- create the normal logind/PAM session and user manager, including
  `XDG_RUNTIME_DIR` and device access;
- acquire and hand off the seat/VT through a supported logind or libseat path;
- run the compositor and desktop as the selected user, never as root;
- track the session process tree and cleanly end it on logout, startup failure
  or compositor crash, then return to the greeter;
- support shutdown and reboot actions without leaving session processes or
  seat ownership behind.

The privileged session supervisor and the per-user compositor need a clear
process boundary. Passwords remain within PAM authentication and must not be
logged or sent over BubbleWM's compositor IPC. The existing lock screen is
only for an already logged-in user and stays a separate operation from login.

## Migration sequence

1. Finish the native DRM/KMS backend and seat/session handling.
2. Implement and review the greeter, PAM/logind session creation, privilege
   separation, logout and crash cleanup.
3. Package BubbleWM for BubbleOS and validate successful login, rejected
   login, logout, restart, recovery VT and system power actions in a VM.
4. Replace the greetd/tuigreet and Wayfire services in desktop-enabled images;
   keep serial and tty1 recovery access available.
5. Document packaging for other distributions with the same Wayland-only
   session contract.

BubbleOS and BubbleWM remain separate repositories. Theme sharing and other
desktop integration should use documented versioned interfaces rather than
merging the projects.
