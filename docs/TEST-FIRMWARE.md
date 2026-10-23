# Testing BatteryGuard 1.0.4 on a Mac with the new charge-limit firmware

Thanks for helping. BatteryGuard 1.0.3 showed you "The background service isn't responding" because your Mac's firmware uses new charge-control keys (`bfF0`, `bfD0`, `bfE0`). Version 1.0.4 supports them: instead of switching charging on and off, it tells the firmware to keep the battery between the limit and 2% below it.

Everything below takes about 10 minutes. Steps 1 and 2 only read values and change nothing. Please send back the output marked with **Send**.

## 1. Install the app (replaces 1.0.3)

1. Quit BatteryGuard 1.0.3 (menu bar icon > **Quit**). Don't turn off the limit.
2. Check the file you received. In Terminal:
   ```
   shasum -a 256 ~/Downloads/BatteryGuard-1.0.4.dmg
   ```
   The result must match the `BatteryGuard-1.0.4.dmg` line in the `SHA256SUMS` file sent with it.
3. Open the dmg and drag BatteryGuard to Applications, replacing the old one.
4. Open BatteryGuard once. macOS blocks it because it's not signed with an Apple Developer ID: open **System Settings > Privacy & Security**, scroll down, click **Open Anyway**. Don't click anything in the panel yet.

## 2. Read-only checks (nothing is written)

```
/Applications/BatteryGuard.app/Contents/MacOS/batteryguard-helper probe
```

**Send** the whole output. What we expect on your Mac (the tool prints Italian labels: `tipo` = type, `valore` = value, `schema rilevato` = detected scheme):

```
bfF0  tipo=...  byte=1  valore=..
bfD0  tipo=...  byte=4  valore=.. 00 00 00  (NN%)
bfE0  tipo=...  byte=4  valore=.. 00 00 00  (NN%)
...
schema rilevato: firmware
```

If the last line isn't `schema rilevato: firmware`, stop here and send the output: BatteryGuard 1.0.4 would not work on your Mac either, and we need those values to add support. If `bfF0`, `bfD0` and `bfE0` show `SMC call failed (0xe00002c1)`, your Mac has the newer firmware (macOS 27 beta 4 and later, also shipped with macOS 15.8 and 26.7) where Apple blocks these keys for third-party apps: please send the output anyway.

Also **send**:

```
sw_vers
sysctl -n machdep.cpu.brand_string
pmset -g batt
```

If Terminal says the helper "cannot be opened" or is "killed", open the app once more with **Open Anyway** (step 1.4) and retry.

## 3. Turn on the limit

1. Click the BatteryGuard icon in the menu bar. With the old service still installed you'll see "BatteryGuard isn't available for this Mac yet" and, below it, "The background service needs an update.": click **Update** and enter your administrator password. If you had uninstalled it, click **Turn on charge limit**.
   If the panel still says "isn't available" after the update, click **Send report**: it opens an email with the technical details (no personal data), send it as is.
2. The panel should show the battery with the limit marker. Leave the limit where you want it (50 to 80%).

## 4. Check that it works

Wait 10 seconds, then:

```
cat "/Library/Application Support/BatteryGuard/status"
```

Expected: `state=running`, `scheme=firmware`, and no `error=` line. **Send** it.

```
/Applications/BatteryGuard.app/Contents/MacOS/batteryguard-helper status
```

Expected line: `limite firmware:   bfF0=0x02 bfD0=80 bfE0=78` (with your limit: upper = limit, lower = limit - 2). **Send** it.

```
cat /Library/Logs/BatteryGuard/helper.log
```

(use `sudo cat ...` if it says permission denied). Expected: `avvio, schema firmware, ...` and `limite firmware impostato: 78-80%`. **Send** the last 20 lines.

Then the real test, with the charger connected:

```
pmset -g batt
```

- Battery above the limit: it should say `not charging` (or `AC attached; not charging present`) and stay there.
- Battery below the limit: it charges up to the limit, then stops. To see it quickly, set the limit 1 or 2% below the current charge in the panel: within a minute `pmset -g batt` should show `not charging`.
- After it stops, charging should resume only when the battery drops 2% below the limit.

**Send** `pmset -g batt` before and after changing the limit, and once more after an hour or so (a sleep in between is fine: the firmware keeps the limit even while the Mac sleeps).

## 5. Go back to normal charging

In the panel: **Turn off limit** > **Turn off**, then your administrator password. This removes the service and switches the firmware limit off (`bfF0` = `00`). Check:

```
/Applications/BatteryGuard.app/Contents/MacOS/batteryguard-helper probe
```

`bfF0` must show `valore=00`, and `pmset -g batt` should show the battery charging again with the charger connected.

If the app doesn't open or something looks stuck, this does the same from Terminal:

```
sudo sh /Applications/BatteryGuard.app/Contents/Resources/uninstall.sh
```

## What to send back

1. `probe` output (step 2, and step 5 after turning off)
2. `sw_vers`, chip, `pmset -g batt` (step 2 and step 4)
3. Status file, `status` output and the last 20 log lines (step 4)
4. Anything that looked wrong, with a screenshot of the panel
