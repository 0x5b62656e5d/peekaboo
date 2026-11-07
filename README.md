# peekaboo

A macOS app that makes your menu bar look cleaner. Requires macOS 27.

- Hides the app menus (File, Edit, View...) until you hover the menu bar, using a macOS 27 setting. The Apple logo and app name stay.
- Hides status icons behind a divider. ⌘-drag icons to the left of the divider to hide them, or to the right to keep them visible.
- Optionally shows hidden icons in a second bar below the menu bar, for when the notch gets in the way.

Click the divider to show or hide icons. Right-click it for Settings.

## Install

peekaboo isn't notarized, so macOS blocks it the first time.

1. Unzip it and move `peekaboo.app` to `/Applications`. It has to be there, because macOS drops the divider for apps run from other folders.
2. Open it, then allow it under System Settings > Privacy & Security > Open Anyway.
3. Grant Accessibility when asked. peekaboo needs it to read where your icons are.
4. If you use the second bar, grant Screen Recording the first time you open it, then reopen peekaboo. It only captures the menu bar, when peekaboo launches and while the second bar is open. Without it, the second bar shows app icons instead.

## Limits

These come from macOS 27:

- Hiding is per app, so all of an app's icons hide together.
- Apple's own icons (clock, Wi-Fi, Control Center) always stay visible.
- The second bar opens with the icons from the last time, then updates them about once a second while it's open, so the screen recording dot stays on until you close it. An icon that doesn't fit in the menu bar shows as its app icon.
- Hiding the app menus is a system setting Apple doesn't document. It stays on after you quit peekaboo, so turn it off in peekaboo's Settings first if you want the menus back. A macOS update could remove it.
- peekaboo uses a private Apple framework, so a macOS update could break hiding. If that happens, all your icons stay visible.

## Build

```sh
scripts/package.sh
```

This writes `build/peekaboo.zip`, signed with your Apple Development certificate.
