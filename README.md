# iOS on Android (Mi 10T Pro edition)

Real Apple iPhone OS, running on a Xiaomi Mi 10T Pro, **without flashing anything**.

| Decision | Choice |
| --- | --- |
| Device | **Xiaomi Mi 10T Pro** (`apollo`). The Galaxy A5 sits this one out. |
| iOS version | **iPhone OS 3.1.3** (build 7E18, 2010), Apple's own unmodified firmware |
| How | An emulated **iPod touch 2nd gen** ([qemu-ios](https://github.com/samhenrigold/qemu-ios)), built from source on the phone and shown in a window |
| Risk to the phone | Nothing gets flashed, rooted or wiped, and the bootloader isn't used. Details under [Safety](#safety-why-this-cant-brick-the-phone). |

---

## First, what those Instagram videos actually are

Nobody has ever booted real, modern iOS on an Android phone, and nobody can:

* **iOS only runs on Apple chips.** It has no drivers for a Snapdragon's display, GPU, modem,
  touchscreen or storage.
* **Every boot stage checks Apple's signature** (SecureROM → iBoot → kernel), and Apple
  signs firmware per device. An Android phone's bootloader can't run any of it.

So the "iOS 18 on my Android!" videos are one of these:

1. **A launcher or theme**: icons, lock screen and Control Center made to look like iOS.
   It's still Android underneath.
2. **A custom ROM with an iOS skin**: same thing, baked into the system.
3. **Fake**: an iPhone filmed in an Android case, or an edited video.

This project does something those videos don't: it runs **Apple's actual code**. It's an
emulator, so it's old iOS in a window, not a replacement for Android.

## Why this device and this version

**Mi 10T Pro over the Galaxy A5:** emulation is pure CPU work. A Snapdragon 865 with 8 GB of
RAM is several times faster than any Galaxy A5's chip with 2–3 GB, and the
unlocked Xiaomi is better documented for tinkering. The A5 would just be slower at the same thing.

**iPhone OS 3.1.3:** the newest iOS that open-source emulators can currently boot to a
usable home screen on hardware like this. It's the classic skeuomorphic one: slide to
unlock, linen and leather, the shiny dock. Newer iPhones (iOS 4 to iOS 14) are being
emulated by research projects, but they need Mac-only graphics acceleration or far
more power than a phone has.

---

## Expectations (please read)

### What success looks like
You type `ios` in a terminal app. A viewer opens and shows a black screen, then the Apple
logo, then, a few minutes later, the iPhone OS 3 lock screen. You **slide to unlock**
and get a real 2010 home screen, running Apple's own code, on your Xiaomi.

| Should work | Shaky | Won't work |
| --- | --- | --- |
| Booting, lock screen, slide to unlock | **Speed**: no GPU, so iOS draws everything in software on an emulated 2008 CPU. Expect choppy animations and laggy scrolling | App Store, iTunes Store, iCloud, YouTube app, Maps (the 2010 servers are gone) |
| Home screen, Settings, Notes, Calculator, Clock, Calendar, Contacts, Photos | **Boot time**: a few minutes, maybe more | Calls, iMessage, FaceTime (it's an iPod touch) |
| Changes saved between boots | Wi-Fi and Safari (`ios start --wifi`): most modern websites refuse 2010-era encryption | 3D games (the GPU bridge is Mac-only) |
| Home / Sleep / Volume buttons, screenshots | Sound (`ios start --sound`) | Pinch-to-zoom (the viewer sends one finger) |
| | | Replacing Android as the phone's OS. It's an app. |

### Honest odds
* **Backup and phone prep (the Mac scripts):** very likely to work first time. They were
  dry-run tested against a simulated phone, including file-copy failures.
* **The emulator on the phone:** this is the experimental part. The emulator is developed
  on macOS. Its source has a proper non-Mac path (software rendering, VNC display), but
  I couldn't find anyone documenting it on Android, and I couldn't compile it in my
  sandbox beforehand. My guess is roughly a coin flip that it boots on the first try.
  The likely failure points are a compile error or Android killing the emulator in the
  background. Both are fixable: send me the logs (see [Troubleshooting](docs/TROUBLESHOOTING.md)).

### Time
* Backup: 10–90 minutes, depending on how full the phone is (USB 2 runs at about 35 MB/s).
* Setup on the phone: 30–60 minutes, unattended (downloads ~1.5 GB and compiles the emulator).
* Each boot of iOS: a few minutes.
* The phone gets warm while iOS runs. Stop it when you're done (`ios stop`).

---

## Safety: why this can't brick the phone

Bricking means breaking the bootloader or the system partitions. This project never touches
either:

* **No flashing, no fastboot, no recovery, no root, no wipes.** The unlocked bootloader
  isn't used at all.
* **Everything runs inside two normal apps** (Termux and AVNC), in their private storage.
  Uninstalling them removes every trace.
* **The backup is read-only.** It copies from the phone and changes nothing.
* **The only system setting changed** is Android's "phantom process killer". It's turned off
  so the emulator isn't killed in the background. It's one value, and the original is
  saved; `mac/03-undo.sh` puts it back.
* **Every download is checked** against a pinned SHA-256 checksum ([config.env](config.env)).
  The emulator source is pinned to an exact commit.
* The scripts **refuse to touch the phone until the backup has finished**.

Worst case, iOS doesn't boot. You uninstall two apps and you're exactly where you started.

---

## What you need
* The Mi 10T Pro, a USB cable, your MacBook, and about 15 GB free on the phone.
* Free space on the Mac's internal SSD for the backup: about as much as the phone's
  used storage.
* About an hour where the phone can sit on a charger.

### On the phone, once: turn on USB debugging
1. Settings → About phone → tap **MIUI version** 7 times ("You are now a developer").
2. Settings → Additional settings → **Developer options**:
   * **USB debugging**: on
   * **Install via USB**: on (MIUI asks you to sign in to a Mi account for this)
   * **USB debugging (Security settings)**: on (lets the script change the background setting)
3. Plug into the Mac. On the phone, tap **Allow** (tick "Always allow from this computer").

## Step 1: back up the phone (Mac)

```bash
git clone -b claude/eager-tesla-btursi https://github.com/tomilabs2011/iOS-on-Android.git ~/iOS-on-Android
```

```bash
cd ~/iOS-on-Android && ./mac/01-backup-phone.sh
```

This creates `~/Desktop/Mi10TPro-backup-<date>/` on the **internal SSD**. Before copying, the
script checks that the Desktop really is on the internal drive and that there's enough free
space. If iCloud "Desktop & Documents" sync is on, it names the folder `….nosync`, so iCloud
never uploads it or evicts it from the SSD.

Inside: all internal storage (photos, videos, downloads, music…), the installers of your
apps, the firmware details, and a SHA-256 fingerprint of every file. The script then
**verifies every file against the phone**, so you'll know if anything didn't copy.

> Without root, Android doesn't let any tool read app data (chats, game saves), SMS or call
> logs. Nothing in this project touches those. Keep your usual Google/Xiaomi/WhatsApp
> backups on if you care about them.

## Step 2: prepare the phone (Mac)

```bash
./mac/02-prepare-phone.sh
```

It installs **Termux** (a Linux terminal) and **AVNC** (a screen viewer) from their official
GitHub releases, turns off the phantom process killer, copies the setup files to
`Download/ios-on-android` on the phone, and opens Termux. You can unplug the phone afterwards.

## Step 3: install (phone)

1. Stop MIUI from killing Termux: Settings → Apps → Manage apps → **Termux** →
   Battery saver → **No restrictions**, and turn on **Autostart**.
2. Put the phone on a charger. In Termux, type:

```bash
bash /sdcard/Download/ios-on-android/android/setup.sh
```

It installs a small Debian Linux inside Termux (no root), compiles the emulator, and downloads
iPhone OS 3.1.3. That takes 30–60 minutes. If it stops halfway, run it again; finished steps
are skipped.

## Step 4: run it

```bash
ios
```

AVNC opens with the iPod screen. **Leave Termux running in the background**; don't swipe it away.

**Make touch feel right:** in AVNC's settings, set the gesture style to **Touchscreen**, so a
tap is a tap and a swipe is a swipe. Exact names vary by AVNC version: if swiping scrolls
instead of dragging, set the one-finger swipe to "remote drag". Slide to unlock is a swipe.

| You want | Do this |
| --- | --- |
| Home button | `h` on AVNC's keyboard, or `ios home` in Termux |
| Sleep/Wake (screen dark? press this) | `p`, or `ios power` |
| Power off | `ios off`, slide to power off, then `ios stop` |
| Volume | `=` / `-`, or `ios volup` / `ios voldown` |
| Screenshot for Instagram | `ios screenshot` (saved to Pictures/iOS-on-Android) |
| Stop | `ios stop` |
| Check it boots without the viewer | `ios selftest` |
| Factory-reset the emulated iPod | `ios reset` |
| Remove everything | `ios uninstall`, then `./mac/03-undo.sh` on the Mac |

---

## If it doesn't work
See **[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)**. Most problems come down to the
phone killing Termux, or a build error that needs a log.

**Plan B, if 3.1.3 can't be made to work:** switch to **iPhone OS 2.1.1** on the original
[devos50/qemu-ios](https://github.com/devos50/qemu-ios) emulator. It's older and simpler,
with official Linux build instructions. Same device, same safety model, one notch back in
time. That's the "if all else fails" version change.

## How it works

```
Android (unchanged)
└─ Termux app ─ proot ─ Debian userland (no root)
   └─ qemu-system-arm, machine "iPod-Touch" (S5L8720 SoC, ARM1176 CPU)
      ├─ Apple bootrom → LLB → iBoot → XNU kernel → SpringBoard   (stock iPhone OS 3.1.3)
      ├─ NAND: read-only base image + copy-on-write overlay (your iPod's changes)
      └─ screen → VNC on 127.0.0.1:5901 → AVNC app (touch → touchscreen)
```

| Path | What |
| --- | --- |
| [config.env](config.env) | Every pinned version, URL and checksum |
| [mac/01-backup-phone.sh](mac/01-backup-phone.sh) | Read-only backup to the Desktop |
| [mac/02-prepare-phone.sh](mac/02-prepare-phone.sh) | Installs the two apps, copies the setup files |
| [mac/03-undo.sh](mac/03-undo.sh) | Puts the phone back as it was |
| [android/setup.sh](android/setup.sh) | Runs in Termux: Debian, build, firmware |
| [android/debian/](android/debian/) | Build script, launcher, screenshot/self-test tool |
| [android/termux/ios](android/termux/ios) | The `ios` command |

## Credits
* [devos50/qemu-ios](https://github.com/devos50/qemu-ios) by Martijn de Vos: the original
  iPod touch 1G/2G emulator and years of reverse engineering.
* [samhenrigold/qemu-ios](https://github.com/samhenrigold/qemu-ios) ("Light Touch"): the fork
  that took the iPod touch 2G to a usable iPhone OS 3.1.3, and publishes the firmware images used here.
* [Termux](https://github.com/termux/termux-app), [proot-distro](https://github.com/termux/proot-distro)
  and [AVNC](https://github.com/gujjwal00/avnc).

iPhone OS is Apple's copyrighted software. The firmware is downloaded from the emulator
project's own release page and stays on your phone. This is a personal tinkering project.
