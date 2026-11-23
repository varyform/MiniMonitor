# Changelog

## Unreleased

- **Temperature on M1 with macOS 27:** the menu bar shows the CPU temperature again instead of `--°`. macOS 27 renamed the M1's core sensors, so when the known ones are missing MiniMonitor now finds the core sensors itself.

## 0.7 — 2026-11-22

- **Marquee names the parent:** the spike's name now says what started it, parent first, such as `nxplay › python3.14`. A shell running a script goes by the script's name rather than `bash`; a command you typed yourself shows on its own. The tooltip and the Busiest menu name launchers the same way.

## 0.6 — 2026-11-22

- **Marquee scrolls steadily:** the name no longer jumps back to its start every 2 seconds; it loops on without a break for as long as the spike lasts.

## 0.5 — 2026-11-22

- **Notarized:** the app is signed with a Developer ID and notarized by Apple, so it opens without a Gatekeeper warning or a trip to Privacy & Security.
- **Smoother marquee:** a long name now loops seamlessly, with a second copy following the first, instead of leaving the box blank between passes, and the end of the name no longer scrolls in blank.

## 0.4 — 2026-11-22

- **Spike marquee:** during a big CPU spike, the graph gives way to the busiest app's name, scrolling. Hover it for its CPU and what started it, such as the `node` behind a test's headless Chrome.
- **Busiest in the menu:** while anything uses half a core or more, the right-click menu lists the top three apps with their CPU and the process that started each. Choose one to open Activity Monitor.

## 0.3 — 2026-11-22

- **System daemons too:** processes run by root and other users, such as Spotlight's or Time Machine's, are watched as well, read through the system's own `ps`. Turn it off with Watch System Daemons in the right-click menu.

## 0.2 — 2026-11-22

- **Stale test browsers:** when headless Chrome left behind by a killed test run keeps using CPU, a notification says so right away, and MiniMonitor quits it 2 minutes later unless you click Quit Now first. The right-click menu lists every stale browser, with Quit Stale Browsers.
- **Unusual load:** if an app keeps more than a core of CPU, or half the GPU, busy for 5 minutes while you're away, you get a notification. Anything you started in the last 15 minutes doesn't count, and neither does a video or call keeping the display awake. Ignore This App silences one, and Ignored Apps in the menu brings it back.
- **Attention dot:** a dot left of the temperature shows while either is going on; hover or right-click to see what.

## 0.1 — 2026-11-22

- **First release:** the hottest CPU core's temperature and a 2-minute CPU load graph in the menu bar. Click to open Activity Monitor; right-click for Start at Login and Quit.
- **Redraws on wake:** the temperature and graph refresh as soon as the display wakes, and the graph doesn't start with a reading averaged over the whole time the screen was off.
- **Sharp on every display:** with a Retina and a non-Retina display side by side, the graph's lines are one pixel thin on both.
