# BatteryGuard

A free, open source menu bar app for Apple Silicon Macs that does one thing: it stops charging at the limit you choose, between 50% and 80%.

Built for Macs that stay plugged in all day and night, so the battery doesn't sit at 100%.

![BatteryGuard](docs/stato-2-en.png)

## Requirements

- Mac with Apple Silicon (M1 or later)
- macOS 13 Ventura or later

## Install

1. Download `BatteryGuard-x.y.z.dmg` from [Releases](../../releases/latest).
2. Open it and drag BatteryGuard to Applications.
3. BatteryGuard is not signed with an Apple Developer ID, so macOS blocks it the first time. Open **System Settings > Privacy & Security**, scroll down and click **Open Anyway**. You may need to do this for the disk image and then for the app.
4. Click **Turn on charge limit** and enter your administrator password. This is needed once, to install the background service that controls charging.

Check the download against `SHA256SUMS` if you want:

```bash
shasum -a 256 -c SHA256SUMS
```

## How it works

- The app installs a small background service (`/Library/PrivilegedHelperTools/com.alessiocardelli.batteryguard.helper`, started by `launchd`).
- Every few seconds the service reads the battery level. At the limit it tells the Mac's power controller (SMC key `CHTE`, or `CH0B`/`CH0C` on older firmware) to stop charging; it resumes 2% below the limit.
- The limit is stored in `/Library/Application Support/BatteryGuard/config`. Changing it from the app doesn't ask for your password again.
- When the service stops or is removed, charging is turned back on.

## Uninstall

Click **Turn off limit** in the app and enter your password. This removes the service and its files and turns charging back on. Then delete the app.

macOS may keep an entry from "Unknown Developer" under **System Settings > General > Login Items** after uninstalling. It's left over by the system and does nothing.

## Known limits

- While the Mac is asleep the service can't act, so the battery may charge above the limit.
- Intel Macs are not supported.

## Build

Requires the Xcode Command Line Tools.

```bash
./scripts/build.sh
./scripts/test.sh
```

## License

MIT
