<p align="center">
  <img src="docs/media/banner.svg" alt="Oz, a tiling window manager for macOS" width="100%">
</p>

<p align="center">
  <img alt="macOS 14+" src="https://img.shields.io/badge/macOS-14%2B-1c8a5c?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 5.9" src="https://img.shields.io/badge/Swift-5.9-f2bd3a?style=flat-square&logo=swift&logoColor=white">
  <img alt="Trackpad gestures" src="https://img.shields.io/badge/trackpad-three--finger%20swipe-7fd6a3?style=flat-square">
</p>

# Oz

> **About this repository.** oz-wm-macos is the [Oz window manager](https://github.com/AyberkA0/oz-wm) wrapped for macOS. It is not a window manager in the full sense: macOS does not let third-party software replace its window server, so Oz runs as an ordinary app that rearranges other apps' windows through the Accessibility API, with workarounds where the system does not allow what it needs (such as snapshots for windows that slide off the top of the screen). The actual window manager is [oz-wm](https://github.com/AyberkA0/oz-wm), a Wayland compositor for Linux that draws every window itself.

**Oz is a scrolling tiling window manager for macOS.** Instead of shrinking every window to fit the screen, it places them one after another on an endless **vertical strip** and treats the screen as a view onto that strip. Every window keeps a usable size; you move along the strip by **swiping up and down with three fingers**, and it settles on a window edge when you let go.

```
┌──────────── screen ───────────┐
│ ┌───────────────────────────┐ │
│ │        Terminal           │ │ ← focused
│ └───────────────────────────┘ │
│ ┌────────────┐ ┌────────────┐ │
│ │   Safari   │ │   Notes    │ │ ← two windows sharing a row
│ └────────────┘ └────────────┘ │
└───────────────────────────────┘
  ┌───────────────────────────┐
  │          Xcode            │   ← below the screen; swipe up to bring it in
  └───────────────────────────┘
  ┌───────────────────────────┐
  │          Mail             │
  └───────────────────────────┘
```

<p align="center"><img src="docs/media/swipe.gif" alt="Scrolling the strip with a three-finger swipe" width="720"></p>

**Highlights**

- Smooth three-finger scrolling with momentum, independent of how fast apps respond.
- Rows that hold one window or several side by side, with keyboard and mouse control over heights and widths.
- An optional **scroll area**: the strip can occupy only part of the screen (for example the right half), with the rest tiled into fixed regions.
- Drag and drop: split lines show exactly where a window will land; tabs torn off into new windows land where you drop them.
- Per-desktop settings, undo, and layouts that survive restarts.
- Configured from a Settings window or a JavaScript file.

## Contents

- [Installation](#installation)
- [Using the strip](#using-the-strip)
- [The scroll area](#the-scroll-area)
- [Keyboard shortcuts](#keyboard-shortcuts)
- [Settings](#settings)
- [Configuration file](#configuration-file)
- [How it works](#how-it-works)
- [Limitations](#limitations)

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## Installation

Requires macOS 14 or later and Xcode / Swift 5.9 or later.

```bash
make run        # build build/Oz.app and start it
make install    # copy it to ~/Applications/Oz.app and start it
make test       # run the unit tests
make stop       # quit the running Oz
```

On first launch:

1. **Accessibility.** Enable Oz in System Settings › Privacy & Security › Accessibility. Oz starts as soon as the permission is granted.
2. **Trackpad.** If the three-finger vertical swipe is still assigned to Mission Control, Oz offers to take it over. If you choose *Apply*:
   - three fingers up/down scroll the strip;
   - a three-finger double tap opens Mission Control;
   - Mission Control also remains on four fingers up and F3, and App Exposé on four fingers down;
   - menu bar › *Trackpad: Restore macOS Gestures* (or `scripts/trackpad-gestures.sh restore`) reverts the change.

   If the change doesn't take effect immediately, set System Settings › Trackpad › More Gestures › Mission Control to **Swipe Up with Four Fingers**.
3. **Screen Recording** (optional). Needed for windows to slide off the top edge (see [How it works](#how-it-works)). Without it, Oz shrinks such windows instead.

> **Building from source:** with an ad-hoc signature, every build changes the code signature and macOS revokes the Accessibility permission. Run `./scripts/create-signing-cert.sh` once to add a self-signed "Oz Local Signing" identity to your login keychain; `make app` then uses it and permissions persist across rebuilds (`SIGN_ID=...` selects another identity).

The menu bar icon provides: tiling on/off (globally or for the current desktop), live capture, smooth scrolling, the scroll area, Settings, retile, editing and reloading the configuration file, the log, trackpad setup, and quit. When Oz quits, it returns every window it had moved off screen.

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## Using the strip

### Gestures

| Gesture | Action |
|---|---|
| Three fingers up/down | Scroll the strip. On release it continues with your speed and settles on a window edge when it stops near one. Scrolling does not change focus (`swipe.focus: true` focuses the top window); `snap: "always"` scrolls one window at a time. |
| Three-finger double tap | Mission Control (configurable) |
| Three fingers left/right | Handled by macOS (switching desktops) |

Menu bar › *Magnetic Scrolling (Stop at Windows)* makes every swipe come to rest with a window at the top of the scroll area; turned off, scrolling is free and only settles on a window edge it ends near (`swipe.snap`: `"always"` or `"near"`). To reverse the scroll direction, set `swipe.natural: false`. While the strip moves, a thin bar along the right edge shows the visible portion and position; it fades out shortly after scrolling stops.

When Oz opens Mission Control or App Exposé (double tap, `⌃⌥ m`, `⌃⌥⇧ m`), it first brings off-screen windows onto the screen so the overview shows them at a normal size, and returns them to the strip when the overview closes. When the overview is opened another way (four-finger swipe, the Mission Control key), off-screen windows appear small.

<p align="center"><img src="docs/media/mission-control.gif" alt="Mission Control with every window at full size" width="720"></p>

### Rows and widths

- **Resizing with the mouse.** When a window is alone in its row and you narrow it, the rest of the row stays empty and the window stays where you left it: narrowed from the right it keeps its left edge, from the left it keeps its right edge. You can also drag it by its title bar and drop it within the same row to move it sideways. Keyboard width changes preserve its position (shifting it left only as far as needed to fit); at full width it fills the row again.
- **Side by side.** Drag a window next to another (see [split lines](#split-lines)) or use `joinUp`, `joinDown` or `slurpIn`. Rows are never merged automatically.
- **Moving up and down** (`⌃⌥⇧ ↑/↓`). If the adjacent row contains a single narrowed window and the moving window fits beside it, the window joins that row on the side it is already on; pressing again continues past it into a row of its own. Otherwise the rows swap.
- **Keyboard widths** in a single-window row: `cycleWidth` (`⌃⌥ w`) cycles 1/3 → 1/2 → 2/3 → full, `resizeWidth` (`⌃⌥ ,` / `⌃⌥ .`) adjusts in steps, `equalizeRow` (`⌃⌥ =`) restores full width.
- While you resize a window, its neighbours adjust live.
- Keyboard rearrangements (moves, joins, width and height changes, floating) are animated over `animationDuration`, including rows entering and leaving the view.

### Full screen, undo and saved layouts

- **Double-click a title bar** (macOS zoom): the window fills the entire usable screen while the rest of the strip stays in place behind it. Double-click again to return it to its position. The same is available as `toggleMaximize` (`⌃⌥⇧ f`). Rearranging the strip restores the window first.
- **Undo** (`⌃⌥ z`) reverts the strip to its state before the last change: keyboard moves and resizes, drag and drop, mouse resizes, or a window dragged out of the scroll area (which returns to the strip). Up to 20 steps per strip.
- **Saved layouts.** Each desktop's arrangement (rows, heights, widths, positions within rows, scroll position, focus, and windows placed around the scroll area) is saved to `~/Library/Application Support/Oz/layout.json` whenever it changes and when Oz quits, and restored on the next launch. Windows are matched by their window ID (stable while the app keeps running) or, if the app was restarted, by application and title. Unrecognised windows are appended after the restored ones.

<p align="center"><img src="docs/media/maximize.gif" alt="Double-clicking a title bar to fill the screen" width="720"></p>

### Desktop presets

Menu bar › *Save This Desktop as Preset…* saves the apps on the current desktop (for example Chrome, Claude and WhatsApp) together with how their windows are arranged: rows, sizes, positions, the windows placed around the scroll area, and the scroll area itself. Up to five presets can be saved. Choosing *Open Preset: name* applies the preset to the current desktop: apps that are not running are started in the background, and their windows are moved into their saved places as they appear (for up to 30 seconds). Windows are matched by application and, where it still matches, by title. An app that is already running but has no window on this desktop is asked to reopen, as clicking it in the Dock would; most apps open a new window in response. *Delete Preset* removes one.

### Tiling per desktop

Tiling can be turned on or off for each desktop individually with `⌃⌥⇧ esc` (`toggleSpaceTiling`) or menu bar › *Tile This Desktop*. On a desktop with tiling off, Oz leaves all windows where they are (returning any it had moved off screen) and ignores gestures and shortcuts there. The setting is remembered across restarts, and a window moved to such a desktop is released.

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## The scroll area

By default the strip spans the whole screen. A **scroll area** limits it to part of the screen and leaves the rest for windows that should stay in place.

Choose menu bar › *Set Scroll Area…* (or `⌃⌥⇧ a`). The editor hides your windows behind the desktop picture and dims everything outside the selected area. Resize the area by its edges and corners, drag it to move it, draw a new one, or use a preset (left or right half, left or right two thirds, full screen). Return saves, Esc cancels. Windows in the strip are then clipped at the scroll area's top and bottom edges in the same way they slide off the top of the screen. Each desktop has its own scroll area, remembered across restarts; *Reset Scroll Area* returns to the full screen.

<p align="center"><img src="docs/media/zone.gif" alt="The scroll area editor" width="720"></p>

### Split lines

While you drag a window over the scroll area, a rod of glass shows where it will be placed:

- a **horizontal line** between two rows: above the row under the cursor when the cursor is in its upper half, below it otherwise;
- a **vertical line** beside a window when the cursor is near its left or right edge, in which case the two share the row.

Release to move the window into that slot. This also applies to windows already in the strip, so the strip can be reordered by dragging. If no line appears, the window would return to its current position. To reach rows outside the view, hold the cursor in the band along the scroll area's top or bottom edge (15% of its height): the strip starts scrolling after a short delay, faster closer to the edge. Scrolling only becomes available once the drag has passed through the middle of the scroll area, so picking up a window by its title bar near the top does not trigger it.

<p align="center"><img src="docs/media/split-lines.gif" alt="Dragging a window between rows" width="720"></p>

### Windows around the scroll area

With a scroll area set, the remaining screen space holds windows that do not scroll:

- **Dragging a window out** of the scroll area removes it from the strip; the strip closes the gap.
- **Tearing off a tab** (Chrome, Safari, Finder, Terminal and others) outside the scroll area keeps the new window there; inside the scroll area, it joins the strip.
- **Regions.** The space around the scroll area is divided into rectangles: one for each side of the scroll area wide enough to hold a window (150 pt), using as few rectangles as possible and assigning each corner to the side that yields the longest rectangle. A window dropped outside the scroll area is tiled into the region under the cursor. Alone, it fills the region; if the region is already occupied, the region is split along its longer side (stacked in a tall region, side by side in a wide one) and the new window takes the half under the cursor. When a window leaves, the others expand to fill the space; when the scroll area is resized, windows move to the region that now contains them.
- **Returning to the strip.** Dragging a window back into the scroll area inserts it where the split line indicates. This also applies to windows floated with `toggleFloat`; windows that float because of a rule or a fixed size remain floating.

While you drag, a pane of glass (clear Liquid Glass on macOS 26 and later, refracting what is behind it; frosted glass on earlier versions) previews where the window will land: its slot in a region, or the scroll area itself when it would join the strip.

<p align="center"><img src="docs/media/tear-off.gif" alt="Dragging two windows out of the scroll area: the second one splits the region with the first" width="720"></p>

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## Keyboard shortcuts

`⌃⌥` is Control-Option and `⇧` is Shift. Keys follow the active keyboard layout; the defaults assume a US layout. For other layouts, edit the `K` table at the top of the configuration file (for example, Turkish Q uses `ğ ü ö ç - .`).

| Keys | Action | | Keys | Action |
|---|---|---|---|---|
| `⌃⌥ h j k l` / arrows | focus left / down / up / right | | `⌃⌥⇧ h j k l` / arrows | move the window |
| `⌃⌥ 1…9` | go to row n | | `⌃⌥ home` / `end` | first / last row |
| `⌃⌥ [` | join the row above (side by side) | | `⌃⌥ ]` | join the row below |
| `⌃⌥ i` | pull the window below into this row | | `⌃⌥ o` | move the window out of its row |
| `⌃⌥ w` / `⌃⌥⇧ w` | width share 1/3 → 1/2 → 2/3 | | `⌃⌥ =` | equalize the row |
| `⌃⌥ ,` / `⌃⌥ .` | narrower / wider | | `⌃⌥⇧ ,` / `⌃⌥⇧ .` | shorter / taller |
| `⌃⌥ s` | side by side: pull in and equalize | | `⌃⌥⇧ s` | this window 2/3 of the row |
| `⌃⌥ r` / `⌃⌥⇧ r` | cycle height | | `⌃⌥ f` | toggle full height |
| `⌃⌥⇧ f` | fill the screen / return to the strip | | `⌃⌥ z` | undo the last layout change |
| `⌃⌥ c` / `⌃⌥ t` | center / align to top | | `⌃⌥ u` / `⌃⌥ d` | scroll half a screen |
| `⌃⌥⇧ pageup` / `pagedown` | start / end of the strip | | `⌃⌥ esc` | toggle floating |
| `⌃⌥ return` | new Terminal window | | `⌃⌥⇧ q` | close the window |
| `⌃⌥ n` | move to the next display | | `⌃⌥ m` / `⌃⌥⇧ m` | Mission Control / App Exposé |
| `⌃⌥⇧ t` | toggle tiling | | `⌃⌥⇧ esc` | toggle tiling for this desktop |
| `⌃⌥⇧ c` | reload the configuration | | `⌃⌥⇧ a` | edit this desktop's scroll area |
| `⌃⌥ /` | show a shortcut summary | | | |

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## Settings

Menu bar › *Settings…* (⌘,) covers the common options: buttons that scroll the strip a step (*Mouse buttons*: click *Set…* and press a mouse's side button, a key or a media key), starting Oz at login (also *Start at Login* in the menu; macOS lists it under System Settings › General › Login Items), gaps, row width, height and position of new windows, animation length, swipe sensitivity and direction, how scrolling settles and glides, smooth scrolling, how windows at an edge are drawn, the live capture rate and resolution, and the three-finger double tap. Changes take effect immediately and are stored separately from the configuration file, layered on top of it; the file itself is not modified. *Reset to Config* discards them. Shortcuts and window rules are defined in the configuration file.

Menu bar › *Keep Windows Alive (Live Capture)* controls how windows cut off at an edge are drawn. When enabled, they are captured continuously (`livePeekFPS`) so video keeps playing; when disabled, Oz captures a single image when a window reaches the edge, so screen capture (and the system's recording indicator) is active only briefly. *Capture resolution* in Settings (`captureScale`) sets how sharp these images are: 1x (the default) keeps the window's own resolution, while 0.75x, 0.5x and 0.25x use less memory and less work per frame, at the cost of softer text while a window is drawn from an image.

<p align="center"><img src="docs/media/settings.png" alt="The Settings window" width="480"></p>

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## Configuration file

`~/.config/oz/config.js` is plain JavaScript, evaluated with JavaScriptCore. It is created from [examples/config.js](examples/config.js) on first launch and **reloaded automatically when saved**. To validate it:

```bash
make check-config
```

```js
oz.set({
  gap: 10, outerGap: 10, width: 1.0,
  heights: [1/3, 1/2, 2/3, 1],      // presets for cycleHeight
  defaultHeight: 1/2,
  newWindowPosition: "below",       // below | above | end | start
  animationDuration: 0.2,
  topOverflow: "slide",             // slide | shrink | hide
  swipe: { enabled: true, fingers: 3, sensitivity: 1.5, natural: true, snap: "near", snapDistance: 70, momentum: 1.0, focus: false },
  doubleTap: { enabled: true, fingers: 3, action: "missionControl" },
});

oz.bind("ctrl+alt+j", "focusDown");                       // a command name
oz.bind("hyper+return", function () { oz.exec("open -na Terminal"); });  // a function
oz.bind("ctrl+alt+1", function () { oz.setHeight(1/3); });

oz.rule({ app: "Calculator", float: true });               // don't tile
oz.rule({ app: /Code/, title: /Settings/, float: true });  // RegExp, arrays and functions also work
oz.rule({ bundleId: "com.apple.ActivityMonitor", height: 1/3 });
oz.rule({ app: "Some App", ignore: true });                // leave it alone entirely

oz.on("windowCreated", function (w) { oz.log("new:", w.app, w.title); });
oz.set({ doubleTap: { action: function () { oz.appExpose(); } } });
```

**Pass-through apps.** While an app in `passThroughApps` is in front, Oz lets go of all of its shortcuts, and of the swipes made over that app's window, so they reach it; swipes over the strip still scroll it, and the double tap keeps working. The default list covers Moonlight (so its ⌃⌥⇧Q disconnect works), Parsec, Microsoft Remote Desktop, Screen Sharing, VNC Viewer, Jump Desktop, TeamViewer, AnyDesk and GeForce NOW. Entries are bundle ids or app names: `oz.set({ passThroughApps: ["com.moonlight-stream.Moonlight", "UTM"] })`.

**Demo mode.** For showing Oz off: with Demo mode on (Settings, or `demoMode: true`), ⌃⌥⇧O opens a stand-in window themed on L. Frank Baum's *The Wonderful Wizard of Oz*: Kansas, the Yellow Brick Road, the Emerald City and five more, in turn. They are real windows of a little app Oz starts (`OzWM demo`), so they tile, scroll and drag like any other; their content is a plain background in GitHub's colours (light or dark, following the system) with the theme's name, laid out for the window's size. Turning demo mode off closes them.

**`oz` API:** `set`, `settings()`, `bind`, `rule`, `on` (events: `windowCreated`, `windowFocused`, `windowFloated`, `swipeEnded`, `spaceChanged`, `spaceTilingChanged`, `configLoaded`), `command(name, arg)`, one function per command (`oz.focusDown()`, `oz.setHeight(0.5)`, …), `windows()`, `focusedWindow()`, `exec(cmd)` (runs in the background), `shell(cmd)` (returns the output), `notify(title, text)`, `log(...)`.

**Commands:** `focusUp/Down/Left/Right/First/Last`, `focusRow(n)`, `moveUp/Down/Left/Right/First/Last`, `slurpIn`, `barfOut`, `joinUp`, `joinDown`, `cycleWidth`, `cycleWidthBack`, `setWidth(ratio)`, `resizeWidth(±ratio)`, `equalizeRow`, `cycleHeight`, `cycleHeightBack`, `setHeight(ratio|pt)`, `resizeHeight(±ratio)`, `toggleFullHeight`, `center`, `alignTop`, `scrollUp(ratio)`, `scrollDown(ratio)`, `scrollBy(pt)`, `scrollToTop`, `scrollToBottom`, `toggleFloat`, `toggleMaximize`, `closeWindow`, `moveToNextScreen`, `undo`, `retile`, `toggleTiling`, `toggleSpaceTiling`, `editScrollArea`, `openSettings`, `reloadConfig`, `missionControl`, `appExpose`, `showDesktop`, `launchpad`.

Commands can also be sent from the shell (skhd, Raycast, scripts):

```bash
build/Oz.app/Contents/MacOS/OzWM msg focusDown
build/Oz.app/Contents/MacOS/OzWM msg setHeight 0.5
```

<p align="center"><img src="docs/media/road.svg" alt="" width="100%"></p>

## How it works

- **Window control.** Windows are moved and resized through the Accessibility API (`AXUIElement`); new, closed and focused windows are tracked with `AXObserver`. Moves are applied off the main thread on one queue per application, keeping only the most recent target per window, so a slow application never stalls scrolling. Layout runs once per display frame (`CADisplayLink`).
- **Gestures.** Raw trackpad contacts are read from `MultitouchSupport.framework` and turned into swipes and taps by a small recognizer (`Multitouch.swift`, `GestureRecognizer.swift`).
- **Structure.** One strip per desktop and display. The layout logic (the strip, drop slots, drag scrolling, regions around the scroll area, saved layouts) is in the `OzCore` module and covered by unit tests; `OzWM` connects it to macOS.
- **Windows at the top edge.** macOS does not allow a window above the menu bar. With `topOverflow: "slide"` (the default), a window crossing the top edge is moved off screen and drawn in its place from a capture of its own content, clipped at the edge, so it slides out just as it does at the bottom. The partly visible window remains clickable and brings the real window back. With `livePeek`, the capture is refreshed at `livePeekFPS` (at 1x resolution) so video keeps playing. Captures start only when a window reaches the edge and stop after about two seconds without changes, so the system's recording indicator appears only while something is being captured. `topOverflow: "shrink"` (pinned and resized) and `"hide"` never capture. Windows entirely out of view are moved to the bottom-right corner of the screen.
- **Smooth scrolling** (`smoothScroll`, on by default). While the strip moves, every window is drawn from a snapshot and the real windows are moved once when the motion ends, so scrolling stays smooth regardless of how quickly applications respond. Window contents are static during the motion. Oz keeps recent snapshots of visible windows so the next swipe can use them from its first frame. When disabled, only windows of slow applications are drawn this way.
- **Slow applications.** Some applications take 50–120 ms to apply a move. Oz tracks each application's recent worst move time; windows of applications above `slowAppThreshold` (30 ms) are drawn from a capture while the strip moves (`slowAppProxy`).
- **Wallpaper tinting.** macOS tints window backgrounds with the colour of the desktop picture behind them. A window moved off screen loses that tint, so its capture would look greyer than the window itself. Oz turns off System Settings › Appearance › *Allow wallpaper tinting in windows* while it runs and restores your setting when it quits; as a fallback it corrects the tint difference in live captures.
- **Long-running use.** Hidden overlays hold no images, snapshots and other data about closed windows are discarded, and the log is rotated at 2 MB. When idle, Oz does essentially no work.
- Scrolling does not change focus; focus changes when you click a window or use a focus command.

## Limitations

- `MultitouchSupport` is a private framework. If a future macOS version changes it, gestures may stop working while keyboard shortcuts continue to work; the menu then shows "No trackpad found".
- Applications with a minimum window size (some settings windows) make their row at least that tall.
- Windows in native full-screen mode are not tiled.
- Mission Control opened without Oz (four-finger swipe or the Mission Control key) shows off-screen windows at a small size.
- The log is at `~/Library/Logs/OzWM.log` (`debug: true` for verbose output). Main-thread delays are logged as `[stall]` with the code responsible, and slow applications as `[slow]`.

<p align="center"><sub>The animations were recorded with demo mode (⌃⌥⇧O).</sub></p>
