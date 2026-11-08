<p align="center">
  <img src="peekaboo/peekaboo/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="peekaboo's icon">
</p>

<h1 align="center">peekaboo</h1>

<p align="center">
  A tidier menu bar for macOS. Icons you don't need right now stay out of sight until you want them.
</p>

<p align="center">
  <a href="https://github.com/0x5b62656e5d/peekaboo/releases/latest"><img src="https://img.shields.io/github/v/release/0x5b62656e5d/peekaboo?style=for-the-badge&labelColor=333&color=FFB627" alt="Latest version"></a>
  <img src="https://img.shields.io/badge/macOS-27%2B-blue?style=for-the-badge&labelColor=333&color=FFB627" alt="Requires macOS 27 or later">
</p>

<p align="center">
  <a href="https://github.com/0x5b62656e5d/peekaboo/releases/latest/download/peekaboo.zip"><b>Download the latest version</b></a>
  ·
  <a href="https://github.com/0x5b62656e5d/peekaboo/releases">All releases</a>
</p>

## Features

- **Hide menu bar icons.** A small divider sits in your menu bar. Icons to its left hide, icons to its right stay put. Click the divider to peek at the hidden ones.
- **Work around the notch.** Show hidden icons in a second bar just below the menu bar instead, so they never get lost behind the notch. They stay live, so things like CPU meters keep updating.
- **Hide them again automatically.** Revealed icons can tuck themselves away after a delay you pick, from instantly to 10 seconds. peekaboo waits while you're using them.
- **Quiet the app menus.** File, Edit, View and the rest stay hidden until you hover the menu bar. The Apple logo and the app's name always stay.
- **Make it yours.** Pick a chevron, dot, diamond or line for the divider, and launch peekaboo at login.

## Install

peekaboo needs **macOS 27** or later.

> [!NOTE]
> peekaboo isn't notarized by Apple, so macOS may block it the first time you open it. Go to **System Settings > Privacy & Security** and click **Open Anyway**.

1. [Download `peekaboo.zip`](https://github.com/0x5b62656e5d/peekaboo/releases/latest/download/peekaboo.zip) and unzip it.
2. Move `peekaboo.app` into your **Applications** folder. macOS hides the divider for apps run from anywhere else.
3. Open it.
4. Allow **Accessibility** when asked. That's how peekaboo sees where your icons are.

### Permissions

|    Permission    |                                                               Why                                                                     |
| ---------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
|  Accessibility   |                                   To find your menu bar icons and click them for you. Required.                                       |
| Screen Recording | To show your real icons in the second bar. Only needed if you use the second bar. Without it, the second bar shows app icons instead. |

peekaboo only ever looks at the menu bar, when it launches and while the second bar is open. If you grant Screen Recording, reopen peekaboo so it takes effect.

## Usage

- **Choose what hides:** hold ⌘ and drag icons to the left of the divider to hide them, or to its right to keep them visible.
- **Show or hide:** click the divider.
- **Settings:** right-click the divider and pick **Settings…**.

## Known limitations

These come from how macOS 27 works:

- **Apps hide as a whole.** If an app has several icons, they hide or show together.
- **Some icons always stay.** Apple's own icons, like the clock, Wi-Fi and Control Center, are always visible.
- **Call icons hide too.** While your icons are hidden, macOS also hides the phone call icon. Click the divider to see it.
- **The recording dot stays on in the second bar.** The second bar takes a fresh look at your icons about once a second while it's open, so the screen recording dot shows until you close it.
- **Icons that don't fit.** If there's no room for an icon even in the menu bar, the second bar shows that app's icon instead.
- **It uses undocumented parts of macOS.** That includes the app menu hiding, which peekaboo switches on while it runs and off when it quits, even if it's force quit. A macOS update could break hiding. If that happens, your icons simply stay visible.

## Troubleshooting

- **Permissions acting up?** Open Settings, then choose **Help > Reset All Permissions…** from the menu bar. peekaboo forgets its access, reopens and asks again.
- **Divider gone?** Open peekaboo again from Applications. Settings comes up and the divider returns.

## Building from source

You need Xcode 27 or later.

```sh
git clone https://github.com/0x5b62656e5d/peekaboo.git
cd peekaboo
scripts/package.sh
```

This builds `build/peekaboo.zip`. To sign it with your own certificate, set your team under **Signing & Capabilities** in Xcode first.
