# Troubleshooting

When asking for help, the most useful things to send are:

* on the Mac: the script's output, or `backup-log.txt` inside the backup folder
* on the phone (in Termux):

```bash
tail -n 80 ~/.ios-on-android/setup.log
```

```bash
proot-distro login debian -- tail -n 80 /root/ios/logs/build.log
```

```bash
ios log
```

## Mac side

| Symptom | Fix |
| --- | --- |
| "Waiting for the phone..." forever | Use a data cable (some are charge-only), turn on USB debugging, try another USB port or adapter. |
| "hasn't trusted this Mac yet" | Unlock the phone and tap **Allow** on the USB debugging prompt. If it never appears: Developer options → Revoke USB debugging authorizations, then replug. |
| "No Mi 10T Pro found" | The script only works on the Mi 10T Pro. If it really is the right phone on an unusual ROM, add `--any-device`. |
| "Not enough free space on the Mac" | Free space on the internal SSD. The backup goes to the Desktop on purpose, and the scripts won't write it anywhere else unless you pass `--dest`. |
| Some files "didn't match" | Open `verify-report.txt`. Files under `Android/data` are app-private and often unreadable over USB. Photos (`DCIM`), `Download`, `Pictures` etc. should all match. If they don't, re-run the backup. |
| `INSTALL_FAILED_USER_RESTRICTED` | Developer options → **Install via USB** (needs a Mi account and a SIM on some MIUI builds). Or install the two APKs by tapping them in Files → Download → ios-on-android → apks. |
| "MIUI refused the change" | Developer options → **USB debugging (Security settings)** → on, then re-run `02-prepare-phone.sh`. |
| "Your Termux is the old, broken Google Play build" | Uninstall Termux yourself (it may hold your own files), then re-run. |

## Phone side

| Symptom | Fix |
| --- | --- |
| `setup.sh`: "Permission denied" / "No such file" | Run `termux-setup-storage`, tap Allow, retry. |
| `pkg` errors about mirrors | Run `termux-change-repo`, pick another mirror, retry `setup.sh`. |
| The build stops with an error | Send the build log (above). Re-running is safe. |
| The build gets killed or the phone reboots | Too hot or out of memory. Use fewer parallel jobs: `JOBS=2 bash /sdcard/Download/ios-on-android/android/setup.sh` |
| iOS dies when you switch to AVNC | The phantom process killer or MIUI battery saver killed it. Re-run `02-prepare-phone.sh`, set Termux's battery saver to **No restrictions**, and on Android 13+ also check Developer options → **Disable child process restrictions**. |
| AVNC doesn't open | Open AVNC yourself and add a server: host `127.0.0.1`, port `5901`, no password. |
| Black screen for a long time | First boot is slow. Press `p` (the iPod may be asleep). Then `ios log`: the serial console shows how far the kernel got. |
| Black screen, then nothing | Run `ios stop` and `ios selftest 1200`. It boots headless and saves `/sdcard/Download/ios-selftest.png`. |
| "Connect to iTunes" screen | Activation. The image used here should already be activated. Send a screenshot. |
| Taps land in the wrong place, or swipes scroll | AVNC → settings → gestures → **Touchscreen** style, and one-finger swipe = remote drag. Zoom to fit. |
| iOS got into a weird state | `ios stop`, then `ios reset` (factory-resets only the emulated iPod). |
| Want the space back | `ios uninstall`, then `mac/03-undo.sh` (or uninstall Termux and AVNC). |
