# ProximityLock Spoon

[![MIT License](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Hammerspoon Spoon](https://img.shields.io/badge/Hammerspoon-Spoon-FFA500.svg)](https://www.hammerspoon.org/docs/index.html)

A Hammerspoon Spoon that locks your Mac when your Bluetooth LE devices (phone, watch) go out of range. It never unlocks.

## How it decides

1. A small scanner app (`ProximityLockScanner.app`, built from `scan.swift`) streams the tracked devices' advertisements with their RSSI back through a named pipe. It runs as its own app because macOS blames Hammerspoon for a child's Bluetooth access, and Hammerspoon has no Bluetooth usage description, so it would kill the scanner.
2. A Kalman filter smooths each device's RSSI. Between samples its uncertainty grows, so a reading after a gap is trusted more, and a single spike barely moves the estimate. The two noise numbers at the top of `presence.lua` set how much it smooths; see the comment there to tune them.
3. A device counts as **away** when its smoothed RSSI stays under `lockThreshold` for `lockDelay` seconds, or when no advertisement arrives for `missTimeout` seconds. A dip that recovers in time resets the timer. After the Mac sleeps, the scanner restarts and the assessment starts over, so the silence during sleep doesn't count against a device.
4. With several devices, `lockWhen` decides when the Mac locks. `"any"` (the default) locks as soon as one device is away, so a phone left on the desk doesn't keep the Mac open after you walk off with your watch. `"all"` locks only when every device is away, so a phone left in another room doesn't lock you out while your watch is with you; the catch is that a device left near the Mac keeps it unlocked. A device counts as back once its signal is well above the threshold again (8 dB over, for 3 s), and with `"any"` the lock re-arms only once every device is back.

## Requirements

- The Xcode command line tools (`xcode-select --install`). The scanner is compiled the first time the spoon starts, which takes a few seconds, and again whenever the scanner sources change. See [First run](#first-run).
- Bluetooth permission for **ProximityLockScanner**, which macOS asks for the first time the scanner runs (System Settings → Privacy & Security → Bluetooth).
- A device whose advertisements carry a stable name or identifier. Pick it from the list and check that it keeps showing up before relying on it.

## First run

The spoon ships the scanner as source (`scan.swift`, `Info.plist` and the `build-scanner.sh` that compiles them) rather than as a binary, so a release needs no macOS build, and a locally built app is never quarantined by Gatekeeper.

The first `start()` therefore:

1. Shows "building the Bluetooth scanner…" and compiles the app with `swiftc`, ad-hoc signs it, and keeps it in `~/Library/Caches/ProximityLock/<hash of the sources>/`. Apps built from older sources are removed afterwards.
2. Starts the scanner, and macOS asks for Bluetooth permission for **ProximityLockScanner**. Allow it.

Later starts reuse the built app. A rebuilt app has a new signature, so macOS may ask for Bluetooth permission again after the scanner sources change. If the build fails (usually missing command line tools) you get an alert, the log has the compiler's error, and locking stays off until you turn it on again.

## Usage

```lua
hs.loadSpoon("ProximityLock")
  :configure({
    devices = { "Alex’s iPhone" },  -- optional starting list; see "Choosing devices"
    lockThreshold = -75,            -- dBm, the default
    lockDelay = 10,                 -- seconds, the default
    missTimeout = 30,               -- seconds, the default
    lockWhen = "any",               -- "any" (default) or "all"; see "How it decides"
    lockWarning = 3,                -- seconds of warning before locking, the default; 0 = none
  })
  :start()
```

All settings are optional. With no `devices` and none chosen yet, `start()` opens the device picker. Three more can be set the same way: `showMenubar` (default `true`), `logLevel` (`"info"` by default; `"debug"` also logs every sample) and `onAway`, the function that locks (by default `hs.caffeinate.lockScreen()`).

If a device is never heard, it counts as away `missTimeout` seconds after `start()`. With `lockWhen = "any"` that locks the Mac, so don't track a device that is switched off.

## Menu bar

While locking is on, a padlock sits in the menu bar: open while the devices are near, closed once they are judged away. Its menu shows the status, each device's smoothed signal (`≈-60 dBm, seen 2s ago`), the limits in force, **Add or remove devices…** and **Turn off**. While locking is off there is no item.

## Warning before a lock

When the devices are judged away, a small notice counts down (`ProximityLock: locking in 3… (Esc to cancel)`) before the Mac locks. Esc cancels it; the key is only captured during the countdown. `lockWarning` sets the length in seconds, and `0` locks immediately.

- Cancelling skips that lock and starts the assessment over: every device goes back to "looking for the device" with a fresh estimate and fresh timers. If a device really is gone it counts as away again after `lockDelay` (or `missTimeout` if it is silent) and the countdown repeats, so walking off after cancelling still locks, but cancelling repeatedly while the devices stay out of range will keep bringing the countdown back.
- The lock is skipped if the devices are no longer away when the countdown ends, and there is no countdown if the screen is already locked.
- Anyone at the keyboard can press Esc during the countdown, so the warning trades a little security for fewer surprises. Bind your own key to `cancelLock()` if you prefer.

## Choosing devices

Use **Add or remove devices…** in the menu bar item, or call `chooseDevices()`. The spoon listens for six seconds, then lists the named devices in range, strongest first. Pick a device to track it, or pick a ✓ device to stop tracking it; the list stays open so you can change several. Locking restarts with the new list when you dismiss it.

- Unnamed devices (mostly beacons) are hidden unless tracked.
- A device is stored by its CoreBluetooth identifier, which is stable on one Mac but differs between Macs.
- Once you have chosen devices, that list is remembered (in Hammerspoon's settings) and the `devices` setting is no longer used. To go back to `devices`, run `hs.settings.clear("ProximityLock.devices")` in the Hammerspoon console.

## Turning it on and off

```lua
local proximity = hs.loadSpoon("ProximityLock")

proximity:setRunning(false)  -- off (e.g. at home); does nothing if already off
proximity:setRunning(true)   -- on
proximity:toggle()           -- flip, with an on-screen alert
proximity:isRunning()        -- true while on
proximity:bindHotkeys({ toggle = { { "ctrl", "alt", "cmd" }, "l" } })  -- optional
```

`stop()` also kills the scanner, so nothing scans Bluetooth while it is off, and the menu bar item is hidden.

To turn it off at home, use a [MacWatcher](https://github.com/hugoh/MacWatcher.spoon) Wi-Fi hook, which accepts a Lua function in recent versions:

```lua
macWatcher:onWifiChange(function(ssid) proximity:setRunning(ssid ~= "HomeSSID") end)
```

## Tests

`mise run test` runs the busted specs in `spec/`. `scanner.lua` and `warning.lua` are tested against a stubbed `hs`. `init.lua`, `picker.lua` and `menubar.lua` have no specs; the logic they depend on lives in `presence.lua`, which does.
