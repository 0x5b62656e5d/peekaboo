# peekaboo

A macOS app that makes your menu bar look cleaner. Requires macOS 27.

- Fades the app menus (File, Edit, View...) until the pointer is on the left half of the menu bar. The Apple logo and app name stay.
- Hides status icons behind a divider. ⌘-drag icons to the left of the divider to hide them, or to the right to keep them visible.
- Optionally shows hidden icons in a second bar below the menu bar, for when the notch gets in the way.

Click the divider to show or hide icons. Right-click it for Settings.

## Install

peekaboo isn't notarized, so macOS blocks it the first time.

1. Unzip it and move `peekaboo.app` to `/Applications`. It has to be there, because macOS drops the divider for apps run from other folders.
2. Open it, then allow it under System Settings > Privacy & Security > Open Anyway.
3. Grant Accessibility when asked. peekaboo needs it to read where your icons are.
4. If you use the second bar, grant Screen Recording the first time you open it, then reopen peekaboo. It only captures the menu bar, and only when you open the second bar. Without it, the second bar shows app icons instead.

## Limits

These come from macOS 27:

- Hiding is per app, so all of an app's icons hide together.
- Apple's own icons (clock, Wi-Fi, Control Center) always stay visible.
- Opening the second bar takes about 0.7s, or 1.4s the first time, because macOS has to redraw the hidden icons before they can be captured. The screen recording dot shows for about a second each time.
- The second bar shows each icon as it was when opened, and doesn't update while open. An icon that doesn't fit in the menu bar even with the others out of the way shows as its app icon.
- The fade matches your wallpaper when it's set to fill the screen. Other wallpaper scaling modes, or a menu bar with its background turned on, won't match exactly.
- peekaboo uses a private Apple framework, so a macOS update could break hiding. If that happens, all your icons stay visible.

## Build

```sh
scripts/package.sh
```

This writes `build/peekaboo.zip`, signed with your Apple Development certificate.
