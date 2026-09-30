# Kuroko

*Visible to you, not your audience.*

Named after the *kuroko* of kabuki theatre: stagehands dressed in black who work in plain
sight while the audience agrees not to see them.

A menu bar app that keeps Slack out of Teams screen shares. It creates a headless virtual
display named **Kuroko** that mirrors one of your real displays, minus the apps you exclude
(Slack, notification banners and Teams by default). Share the Kuroko display in Teams once
per meeting and switch apps freely.

## Setup

1. `make cert` — one time. Creates a self-signed "Kuroko Dev" code-signing identity so the
   Screen Recording permission survives rebuilds. macOS asks for your password to trust it.
2. `make install` — builds, signs, copies to `~/Applications`, and launches.
3. Grant **Screen Recording** when prompted (System Settings → Privacy & Security). The menu
   shows "Needs Screen Recording permission" until it's granted; capture starts on its own.
4. In Teams: Share → Screen → pick **Kuroko**.

Other targets: `make test`, `make run` (run from `build/` without installing), `make clean`.

## Menu

- **About Kuroko**: name and tagline.
- **Pause / Resume** (⌃⌥⌘P from anywhere): viewers see a frozen frame while paused.
- Because Kuroko records the screen continuously, it's always listed in the macOS
  screen-recording menu bar item. Clicking **Stop Sharing** there stops Kuroko's capture
  (not Teams'); viewers see a frozen frame until you choose **Resume** or press ⌃⌥⌘P.
- **Turn Off / Turn On Kuroko Display**: removes the virtual display (ending any share of it)
  and stops capturing until you turn it back on. Kuroko always starts with it on.
- **Source Display**: which physical display to mirror.
- **Excluded Apps**: toggle entries; *Add Running App* excludes anything else.
- **Frame Rate**: 5, 15, 30 (default) or 60 fps. Lower saves battery; Teams rarely sends
  more than 30.
- **Show Preview**: floating window showing exactly what viewers see.
- **Launch at Login** (works best when installed in `~/Applications`).

## How it works

ScreenCaptureKit captures the source display minus the excluded apps. When an excluded app
launches, viewers see a frozen frame for a fraction of a second until the filter excludes it
(refreshed on app launch/quit, and every 5 s). Capturing the whole display, rather than a list
of included apps, keeps macOS from replacing window buttons with its sharing indicator. Frames are
drawn full-screen on the virtual display, and the cursor is kept off that display.

## Limits

- The virtual display uses CoreGraphics' private `CGVirtualDisplay` API, which can change in a
  macOS update, and it rules out the Mac App Store.
- Where an excluded window was, viewers see whatever is behind it.
- The Kuroko display appears in System Settings → Displays while the app runs.
