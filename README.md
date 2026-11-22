# MiniMonitor

A tiny macOS menu bar app that shows the CPU temperature and a CPU load graph, and nothing else. I built it to replace iStat Menus for those two readings.

- **Temperature:** the hottest CPU core, read from the SMC. This is the same method as the "Hottest CPU" reading in [Stats](https://github.com/exelban/stats), and it lands close to iStat Menus.
- **Load graph:** about 2 minutes of total CPU usage. During a big spike (70% of all cores for 4 seconds), the graph turns into a scrolling marquee with the busiest app's name. Hover it to see its CPU and what started it.
- **Left-click:** opens Activity Monitor.
- **Right-click:** a menu with **Start at Login** and **Quit**, plus whatever the watchdog found. While anything uses half a core or more, **Busiest** lists the top three apps, each with its CPU and the process that started it (e.g. `node` for a test's headless Chrome).
- **Watchdog:** tells you when something unusual is using the CPU or GPU (see below).

It updates every 2 seconds and pauses while the display sleeps. It uses about 0.1–0.2% CPU and about 15 MB of memory.

## Watchdog

- **Stale test browsers:** headless Chrome or chromedriver that a killed test run left behind. These are orphans adopted by launchd that carry Chrome's automation flag, the same test the projects' own sweeps use. When one keeps using CPU, you get a notification at once, whatever you're doing. MiniMonitor quits it 2 minutes later unless you click **Quit Now** first. The right-click menu lists every stale browser, idle ones too, with **Quit Stale Browsers**.
- **Unusual load:** an app, with its helpers counted together, that averages more than one core of CPU or half the GPU for 5 minutes while you've been away from the keyboard and mouse for 5 minutes. Processes started in the last 15 minutes don't count, since that's you at work, and nothing is raised while something keeps the display awake, such as a video or a call. Each alert has **Ignore This App**, and **Ignored Apps** in the menu undoes it.
- While either is going on, a dot shows left of the temperature. The tooltip and the right-click menu say what it is.

It scans processes every 30 seconds, also while the display sleeps, which adds about 0.1% CPU. Processes run by root and other users, mostly system daemons, are read through `/bin/ps`, which macOS installs setuid root, so no helper or password is needed. **Watch System Daemons** in the menu turns that off.

## Requirements

- An Apple Silicon Mac (M1–M5) running macOS 13 or later. On Intel Macs the load graph works, but the temperature shows `--°`.
- Xcode, to build it, and [mise](https://mise.jdx.dev), which installs the pinned Swift toolchain (`mise install`).

## Install

Download the zip from [Releases](https://github.com/varyform/MiniMonitor/releases), unzip it and move MiniMonitor.app to Applications. It isn't notarized, so the first time, open it, then choose **Open Anyway** in System Settings › Privacy & Security.

## Build

```sh
mise run build     # builds build/MiniMonitor.app
mise run install   # also copies it to /Applications and launches it
mise run ci        # format lint, tests and the app build
```

`mise tasks` lists the rest (`run`, `test`, `lint`, `format`, `release`, and `load`, which pegs every core for 30 seconds so you can see the spike marquee).

Install to `/Applications` before you turn on **Start at Login**.

## License

[MIT](LICENSE)
