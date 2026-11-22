# MiniMonitor

A tiny macOS menu bar app that shows the CPU temperature and a CPU load graph, and nothing else. I built it to replace iStat Menus for those two readings.

- **Temperature:** the hottest CPU core, read from the SMC. This is the same method as the "Hottest CPU" reading in [Stats](https://github.com/exelban/stats), and it lands close to iStat Menus.
- **Load graph:** about 2 minutes of total CPU usage.
- **Left-click:** opens Activity Monitor.
- **Right-click:** a menu with **Start at Login** and **Quit**.

It updates every 2 seconds and pauses while the display sleeps. It uses about 0.1–0.2% CPU and about 15 MB of memory.

## Requirements

- An Apple Silicon Mac (M1–M5) running macOS 13 or later. On Intel Macs the load graph works, but the temperature shows `--°`.
- Xcode, to build it, and [mise](https://mise.jdx.dev), which installs the pinned Swift toolchain (`mise install`).

## Build

```sh
mise run build     # builds build/MiniMonitor.app
mise run install   # also copies it to /Applications and launches it
mise run ci        # format lint, tests and the app build
```

`mise tasks` lists the rest (`run`, `test`, `lint`, `format`).

Install to `/Applications` before you turn on **Start at Login**.

## License

[MIT](LICENSE)
