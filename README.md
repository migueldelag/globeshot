# Globeshot

Tap the 🌐 key on its own for an area screenshot that's on the clipboard and saved as the usual file the moment you
finish selecting, with a thumbnail card in the corner. It lives in the menu bar and starts at login. ⇧⌘4 itself is
untouched.

## Setup

1. `./build.sh` builds the app, installs it to `~/Applications/Globeshot.app` and starts it.
2. Allow **Input Monitoring** when macOS asks (System Settings > Privacy & Security > Input Monitoring). When macOS
   offers to quit and reopen the app, choose Quit & Reopen.
3. Allow **Accessibility** when macOS asks (System Settings > Privacy & Security > Accessibility).
4. In System Settings > Keyboard, set **Press 🌐︎ key to** to **Do Nothing**. Otherwise every tap also opens the emoji
   picker or switches the input source. (Keyboard Shortcuts > Modifier Keys > **Globe (🌐︎) key: No Action** also
   stops that, and the app still works, but it turns the key off for macOS completely, so 🌐 combos stop working too.)
5. Allow access to the **Desktop** folder when macOS asks. The app saves the screenshot file there.

The menu bar icon stays dimmed until steps 2 and 3 are done, and its menu links to whatever is still missing.

## How it works

- The app reads 🌐 straight from the keyboard over IOHID (Apple vendor page 0xFF, usage 0x03). When "Press 🌐 key to"
  is set to Do Nothing, macOS sends no key event for 🌐, so a regular event tap never sees it.
- A press counts as a tap when 🌐 is down for under 0.5 s, no other modifier is held, and no other key goes down
  in the meantime. 🌐←, 🌐⌫, 🌐F and the other 🌐 shortcuts keep working.
- On a tap it posts ⌃⇧⌘4, macOS's own "copy selected area to the clipboard" screenshot, so the crosshair is macOS's
  and the image is on the clipboard the moment you finish selecting. Space still switches to capturing a window.
- The app then saves the same image the way ⇧⌘4 would: in your screenshot folder (the Desktop by default), named
  "Screenshot 2026-09-29 at 11.07.51 AM.png", PNG at 144 DPI on Retina, tagged as a screenshot for Spotlight,
  extension hidden.
- A card like macOS's floating thumbnail fades in at the bottom right and leaves after 5 seconds, or stays while the
  pointer is on it. Click it to open the screenshot in Preview, drag it into another app or a folder (they get a copy;
  the saved file stays), swipe it away, or right-click for Show in Finder and Delete. macOS's own card can't be used:
  it holds the image until it goes away, and dragging it means the file is never saved.
- The app only receives the 🌐 key's up and down state. For other keys it just asks macOS how long ago one was
  last pressed. Between taps nothing runs. While the crosshair is up, the app waits for the system's `screencapture`
  process to exit, which is a process event, not polling.

## Notes

- Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.miguel.globe-screenshot"'` (the full path
  matters in zsh, where `log` is a built-in command)
- `build.sh` signs with the local "FXMic Dev" identity so permission grants survive rebuilds. Use
  `SIGN_IDENTITY="Other Identity" ./build.sh` to pick another one. Ad hoc signing works, but then you have to grant
  the permissions again after every rebuild.
- Open at Login turns on the first time the app runs. You can turn it off from the menu.
- To uninstall: turn off Open at Login, quit the app, delete it from `~/Applications`, and remove it from Input
  Monitoring, Accessibility and Files & Folders.
