enum DefaultConfig {
    static let source = #"""
// ~/.config/oz/config.js — Oz Window Manager
//
// Plain JavaScript, like PaperWM's user.js. Oz reloads it as soon as you save.
// Errors show up in the Oz menu in the menu bar; log: ~/Library/Logs/OzWM.log
//
// Layout: the screen scrolls over a vertical strip of ROWS. A row holds one window or
// several side by side (like panels on a comic book page).

// ──────────────────────────────── Look & behaviour ────────────────────────────────
oz.set({
  gap: 10,                       // space between windows (pt)
  outerGap: 10,                  // space at the screen edges (pt)
  width: 1.0,                    // row width as a fraction of the screen width

  heights: [1/3, 1/2, 2/3, 1],   // cycleHeight presets (fraction of the screen height)
  widths: [1/3, 1/2, 2/3],       // cycleWidth presets (share of the row)
  resizeStep: 0.05,              // step for resizeWidth / resizeHeight
  defaultHeight: 1/2,            // height of a new window
  keepInitialHeights: true,      // keep the heights windows already have when Oz starts
  newWindowPosition: "below",    // below | above | end | start (relative to the focused window)
  animationDuration: 0.2,        // seconds; 0 = no animation

  topOverflow: "slide",          // window leaving the top edge: "slide" | "shrink" | "hide"
  livePeek: true,                // the half-visible window at the top stays live (video keeps playing)
  livePeekFPS: 12,               // frame rate of the live peek
  captureScale: 1,               // window capture resolution: 1 = the window's own (lossless), 0.75 | 0.5 | 0.25
  slowAppProxy: true,            // windows of slow apps are moved as images while scrolling
  smoothScroll: true,            // all windows move as images while scrolling (smoothest; content pauses)
  slowAppThreshold: 30,          // ms; an app slower than this to move a window counts as slow
  minVisible: 80,

  swipe: {
    enabled: true,
    fingers: 3,
    sensitivity: 1.5,            // 1.0 = a full trackpad-height swipe scrolls about one screen
    natural: true,               // set to false if the direction feels reversed
    snap: "near",                // "near": free, settles on a window edge when close | "always" | "off"
    snapDistance: 70,            // pt
    momentum: 1.0,               // glide after release; 0 = none
    focus: false,                // scrolling doesn't change focus (true: focus the top window after)
  },

  doubleTap: {
    enabled: true,
    fingers: 3,
    action: "missionControl",    // "appExpose" | "showDesktop" | "launchpad" | a command | function
  },

  // While one of these apps is in front, Oz lets go of its shortcuts (e.g. Moonlight's
  // ⌃⌥⇧Q disconnect) and of swipes made over its window, so the app gets them. Swipes
  // over the strip still scroll it; the double tap keeps working. Bundle ids or app names.
  passThroughApps: [
    "com.moonlight-stream.Moonlight", "tv.parsec.www", "com.microsoft.rdc.macos",
    "com.apple.ScreenSharing", "com.realvnc.vncviewer", "com.p5sys.jump.mac.viewer",
    "com.teamviewer.TeamViewer", "com.anydesk.anydeskmacos", "com.nvidia.gfnpc.mall",
  ],

  // Buttons that scroll the strip one step (easiest to pick in Settings › Mouse buttons):
  // "mouse:3" (a side button), "key:<code>:<modifiers>", "media:<code>"; "" for none.
  // scrollButtons: { up: "mouse:3", down: "mouse:4" },
  demoMode: false,               // ctrl+alt+shift+o opens Wizard of Oz demo windows (also in Settings)
  debug: false,                  // verbose log
});

// ─────────────────────────────────── Shortcuts ───────────────────────────────────
// Modifiers: cmd, alt (option), ctrl, shift, hyper (= all four), meh (ctrl+alt+shift)
var M = "ctrl+alt";              // main modifier: ⌃⌥
var S = M + "+shift";            // move / secondary: ⌃⌥⇧

// Keys are looked up in the active keyboard layout ("ö" means the key that types ö).
// These are for a US layout; on Turkish Q use ğ ü ö ç - . instead.
var K = {
  joinUp:   "[",
  joinDown: "]",
  narrower: ",",
  wider:    ".",
  equalize: "=",
  help:     "/",
};

function bind(keys, action) {    // bind one action to several keys
  [].concat(keys).forEach(function (k) { oz.bind(k, action); });
}

// ── Navigation ──
bind([M + "+k", M + "+up"],    "focusUp");
bind([M + "+j", M + "+down"],  "focusDown");
bind([M + "+h", M + "+left"],  "focusLeft");     // panel to the left in the same row
bind([M + "+l", M + "+right"], "focusRight");    // panel to the right in the same row
bind(M + "+home", "focusFirst");
bind(M + "+end",  "focusLast");
for (var n = 1; n <= 9; n++) {                    // ⌃⌥1…9: go to row n
  (function (row) { oz.bind(M + "+" + row, function () { oz.focusRow(row); }); })(n);
}

// ── Moving ──
bind([S + "+k", S + "+up"],    "moveUp");        // move the row up (takes a panel out of its row)
bind([S + "+j", S + "+down"],  "moveDown");
bind([S + "+h", S + "+left"],  "moveLeft");      // within the row
bind([S + "+l", S + "+right"], "moveRight");
bind(S + "+home", "moveFirst");
bind(S + "+end",  "moveLast");

// ── Horizontal layout: rows and panels ──
bind(M + "+" + K.joinUp,   "joinUp");     // put the window into the row above (on the right)
bind(M + "+" + K.joinDown, "joinDown");   // put the window into the row below (on the left)
bind(M + "+i", "slurpIn");                // pull the window below into this row
bind(M + "+o", "barfOut");                // move this window out of its row, below it
bind(M + "+w", "cycleWidth");             // share of the row: 1/3 → 1/2 → 2/3 (→ full when alone)
bind(S + "+w", "cycleWidthBack");
bind(M + "+" + K.wider, "resizeWidth");                             // wider
bind(M + "+" + K.narrower, function () { oz.resizeWidth(-0.05); }); // narrower
bind(M + "+" + K.equalize, "equalizeRow");                          // equal widths (full when alone)

// Ready-made arrangements
bind(M + "+s", function () {       // side by side: pull in the window below, split evenly
  oz.slurpIn(); oz.equalizeRow();
});
bind(S + "+s", function () {       // main + side: this panel 2/3, the rest share 1/3
  oz.setWidth(2/3);
});

// ── Height ──
bind(M + "+r", "cycleHeight");     // 1/3 → 1/2 → 2/3 → full
bind(S + "+r", "cycleHeightBack");
bind(M + "+f", "toggleFullHeight");
bind(S + "+f", "toggleMaximize");  // fill the screen / back into the strip (also: double click the title bar)
bind(S + "+" + K.wider, "resizeHeight");                             // taller
bind(S + "+" + K.narrower, function () { oz.resizeHeight(-0.05); }); // shorter

// ── Scrolling ──
bind(M + "+c", "center");          // center the focused window
bind(M + "+t", "alignTop");        // align the focused window with the top edge
bind([M + "+u", M + "+pageup"],   "scrollUp");     // half a screen up
bind([M + "+d", M + "+pagedown"], "scrollDown");   // half a screen down
bind(S + "+pageup",   "scrollToTop");
bind(S + "+pagedown", "scrollToBottom");

// ── Windows ──
bind(M + "+escape", "toggleFloat");   // take out of / back into the tiling
bind(M + "+n", "moveToNextScreen");
bind(S + "+q", "closeWindow");
bind(M + "+return", function () {     // new Terminal window (opens below the focused one)
  oz.exec("open -na Terminal");
});

// ── System ──
bind(M + "+m", "missionControl");
bind(S + "+m", "appExpose");
bind(S + "+t", "toggleTiling");          // everywhere
bind(S + "+escape", "toggleSpaceTiling"); // just this desktop (floating desktop), remembered
bind(S + "+a", "editScrollArea");      // set the part of the screen this desktop scrolls in
bind(S + "+c", "reloadConfig");
bind(M + "+z", "undo");               // undo the last layout change (moves, sizes, drags)

// Shortcut cheat sheet (⌃⌥ + K.help)
oz.bind(M + "+" + K.help, function () {
  oz.notify("Oz shortcuts (⌃⌥)",
    "hjkl/arrows focus · ⇧ moves · " + K.joinUp + " " + K.joinDown + " join row · i/o pull in/out · " +
    "w width · " + K.narrower + " " + K.wider + " narrower/wider · " + K.equalize + " equalize · " +
    "r height · f full · c center · u/d scroll · 1-9 row · esc float · " +
    "⇧f fill screen · ⇧esc desktop tiling · ⇧a scroll area");
});

// ───────────────────────────────────── Rules ─────────────────────────────────────
// app / title / bundleId: a string, RegExp, array or function.
// float: not tiled · ignore: Oz leaves it alone · height: initial height (0..1)
oz.rule({ app: ["System Settings", "Sistem Ayarları"], float: true });
oz.rule({ app: ["Calculator", "Hesap Makinesi"], float: true });
oz.rule({ app: "Finder", title: /^(Copy|Kopyala|Info|Bilgi|Move|Taşı)/, float: true });
oz.rule({ app: "Karabiner-EventViewer", float: true });
oz.rule({ bundleId: "com.apple.ActivityMonitor", height: 1/3 });
oz.rule({ app: "Terminal", height: 1/2 });

// ───────────────────────────────────── Events ────────────────────────────────────
// windowCreated, windowFocused, swipeEnded, spaceChanged, configLoaded
// oz.on("windowCreated", function (w) { oz.log("new window:", w.app, w.title); });
"""#
}
