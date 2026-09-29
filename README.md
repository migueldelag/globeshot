# Globe Screenshot

Tap the 🌐 key on its own to take an area screenshot, the same as ⇧⌘4. It lives in the menu bar and starts at login.

## Setup

1. `./build.sh` builds the app, installs it to `~/Applications/Globe Screenshot.app` and starts it.
2. Allow **Input Monitoring** when macOS asks (System Settings > Privacy & Security > Input Monitoring). When macOS
   offers to quit and reopen the app, choose Quit & Reopen.
3. Allow **Accessibility** when macOS asks (System Settings > Privacy & Security > Accessibility).
4. In System Settings > Keyboard, set **Press 🌐 key to** to **Do Nothing**. Otherwise every tap also opens the emoji
   picker or switches the input source.

The menu bar icon stays dimmed until steps 2 and 3 are done, and its menu links to whatever is still missing.

## How it works

- The app reads 🌐 straight from the keyboard over IOHID (Apple vendor page 0xFF, usage 0x03). When "Press 🌐 key to"
  is set to Do Nothing, macOS sends no key event for 🌐, so a regular event tap never sees it.
- A press counts as a tap when 🌐 is down for under 0.5 s, no other modifier is held, and no other key goes down
  in the meantime. 🌐←, 🌐⌫, 🌐F and the other 🌐 shortcuts keep working.
- On a tap it posts ⇧⌘4, so macOS's own screenshot tool runs with your settings: save location, floating thumbnail,
  ⌃ to copy to the clipboard, Space to capture a window.
- The app only receives the 🌐 key's up and down state. For other keys it just asks macOS how long ago one was
  last pressed. Between taps nothing runs: no timers, no polling.

## Notes

- Logs: `/usr/bin/log show --last 10m --predicate 'subsystem == "com.miguel.globe-screenshot"'` (the full path
  matters in zsh, where `log` is a built-in command)
- `build.sh` signs with the local "FXMic Dev" identity so permission grants survive rebuilds. Use
  `SIGN_IDENTITY="Other Identity" ./build.sh` to pick another one. Ad hoc signing works, but then you have to grant
  the permissions again after every rebuild.
- Open at Login turns on the first time the app runs. You can turn it off from the menu.
- To uninstall: turn off Open at Login, quit the app, delete it from `~/Applications`, and remove it from Input
  Monitoring and Accessibility.
