# Mac Pulse

Mac Pulse is a native macOS menu bar app that keeps an eye on your Mac and your internet connection. Four small symbols in the menu bar change color when something needs attention: download, memory, temperature, and CPU. Click them for a compact dashboard, or open the full Command Center app for detail.

## Download

Get the **.dmg** file from the [latest release](https://github.com/LukeMainwaring0/mac-pulse/releases/latest), open it, and drag Mac Pulse into Applications. It runs on macOS 13 or later, on Apple silicon and Intel Macs.

The app isn't notarized by Apple yet, so the first time you open it macOS blocks it. Click **Done**, then go to **System Settings › Privacy & Security** and click **Open Anyway** next to Mac Pulse. You only need to do this once.

## What it does

- **Menu bar at a glance.** Four outline symbols are tinted green, yellow, orange, or red to match the status dots in the menu. Battery information appears after a thin divider only when it matters (on battery, or at 80% or below).
- **Menu.** Download speed, memory, battery power in and out, temperature, CPU and GPU load, Mac health (battery cycles, storage, recent kernel panics), and quick controls for Test now, Open at login, and Clamshell.
- **Command Center.** A full window with live graphs for network, CPU and GPU, memory, storage, battery and power, temperature, apps, connected devices, and health.
- **Accurate speed tests.** Speed comes from Apple's built-in `networkQuality` tool, download only, for four seconds. Mac Pulse tests on launch, wake, network changes, when you open the menu and the last result is more than 15 minutes old, when the connection suddenly slows, and every hour as a backup. It never tests automatically on hotspots or in Low Data Mode.
- **Connection check.** Every minute Mac Pulse fetches Apple's 68-byte connectivity page and measures how long the server takes to answer. That drives the download status color and shows "Offline" when the connection drops.
- **Alerts.** When any status turns red, Mac Pulse sends one notification per episode, with an optional custom alert sound.
- **Clamshell.** Keeps the Mac awake with the lid closed while on power (uses `pmset disablesleep` and asks for an administrator password).

Each speed test uses roughly 25 MB per 50 Mbps of line speed (about 200 MB on a 500 Mbps connection), so expect a few GB per day on a fast line.

## Requirements

- macOS 13 or later. The Liquid Glass look needs macOS 26 or later.
- Xcode command line tools with Swift 5.10 or later.

## Build and run

```sh
./script/build_and_run.sh            # debug build, then launch
./script/build_and_run.sh --install  # release build into /Applications
swift test                           # run the tests
```

Other modes: `--verify`, `--logs`, `--telemetry`, `--measure` (one speed test, printed as JSON), `--stats`, and `--package`.

## Forking

You're welcome to fork Mac Pulse. Before shipping your own build, change these in `script/build_and_run.sh` so your copy doesn't collide with this one or try to update from it:

- `BUNDLE_ID`
- `SPARKLE_FEED_URL` and `SPARKLE_PUBLIC_ED_KEY` (generate your own Sparkle keys), or remove Sparkle
- `CODESIGN_IDENTITY` if you sign with a Developer ID

`sound-picker/` is an optional local web page for auditioning and choosing the alert sound. Run `python3 sound-picker/server.py` and open the printed address.

## Project layout

- `Sources/InternetSpeed/` – the app (AppKit status item and menu, SwiftUI views)
- `Tests/InternetSpeedTests/` – unit and rendering tests
- `Resources/AppIcon.icon` – layered app icon
- `script/` – build, install, and release scripts
- `DISTRIBUTION.md` – notarized release and Sparkle update process

## License

MIT. See [LICENSE](LICENSE).
