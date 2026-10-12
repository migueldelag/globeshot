# Globe Screenshot

Tap the 🌐 key on its own for macOS's own area screenshot, the same as ⇧⌘4 with its floating card, and the image also
goes on the clipboard once macOS saves the file. It lives in the menu bar and starts at login. ⇧⌘4 itself is untouched.

## Setup

1. `./build.sh` builds the app, installs it to `~/Applications/Globe Screenshot.app` and starts it.
2. Allow **Input Monitoring** when macOS asks (System Settings > Privacy & Security > Input Monitoring). When macOS
   offers to quit and reopen the app, choose Quit & Reopen.
3. Allow **Accessibility** when macOS asks (System Settings > Privacy & Security > Accessibility).
4. In System Settings > Keyboard, set **Press 🌐︎ key to** to **Do Nothing**. Otherwise every tap also opens the emoji
   picker or switches the input source. (Keyboard Shortcuts > Modifier Keys > **Globe (🌐︎) key: No Action** also
   stops that, and the app still works, but it turns the key off for macOS completely, so 🌐 combos stop working too.)
5. Allow access to the **Desktop** folder when macOS asks. The app reads the saved screenshot to copy it.

The menu bar icon stays dimmed until steps 2 and 3 are done, and its menu links to whatever is still missing.

## How it works

- The app reads 🌐 straight from the keyboard over IOHID (Apple vendor page 0xFF, usage 0x03). When "Press 🌐 key to"
  is set to Do Nothing, macOS sends no key event for 🌐, so a regular event tap never sees it.
- A press counts as a tap when 🌐 is down for under 0.5 s, no other modifier is held, and no other key goes down
  in the meantime. 🌐←, 🌐⌫, 🌐F and the other 🌐 shortcuts keep working.
- On a tap it posts ⇧⌘4, so macOS's own screenshot tool runs with your settings: save location, floating thumbnail,
  Space to capture a window.
- When macOS saves the file, the app copies the image to the clipboard too. With the floating thumbnail on, macOS
  saves the file only when the thumbnail goes away (after about 5 seconds, or at once if you swipe it off), so the
  copy happens then. macOS holds the image inside the thumbnail until that point, so no app can copy it sooner. To
  get the file and the copy right away, turn off Show Floating Thumbnail in ⇧⌘5 > Options.
- The app only receives the 🌐 key's up and down state. For other keys it just asks macOS how long ago one was
  last pressed. Between taps nothing runs. After a tap, the app waits for a file system event from the screenshot
  folder (for up to 5 minutes), with no polling.

## Notes

- Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.miguel.globe-screenshot"'` (the full path
  matters in zsh, where `log` is a built-in command)
- `build.sh` signs with the local "FXMic Dev" identity so permission grants survive rebuilds. Use
  `SIGN_IDENTITY="Other Identity" ./build.sh` to pick another one. Ad hoc signing works, but then you have to grant
  the permissions again after every rebuild.
- Open at Login turns on the first time the app runs. You can turn it off from the menu.
- To uninstall: turn off Open at Login, quit the app, delete it from `~/Applications`, and remove it from Input
  Monitoring, Accessibility and Files & Folders.
