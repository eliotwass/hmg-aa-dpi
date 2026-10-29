# hmg-aa-dpi

A NEMESIS package (`aa.dpi`) that changes the DPI Android Auto renders at on Hyundai/Kia Gen5W head units (developed for a 2023 Ioniq 5 US, `NEEV.USA.0000.V015.012.260507`). A lower DPI makes AA's text, icons and buttons smaller and fits more map and content on the screen.

It does what [aa-proxy-rs](https://github.com/aa-proxy/aa-proxy-rs)'s `dpi` setting does, but on the head unit itself. That means it works over wired and wireless AA and needs no proxy hardware. It's a separate package from [egmp-aa-ev-feat](https://github.com/willemcvu/egmp-aa-ev-feat) and works alongside it (see [Install order](#install-order-with-egmp-aa-ev-feat--leafia)).

Optionally (`TAP_LIMIT=off`) it also removes AA's tap/scroll limit while driving, the "you've scrolled a lot" lockout, the same way aa-proxy-rs's `remove_tap_restriction` does. See [Tap/scroll limit](#tapscroll-limit-tap_limitoff).

> [!WARNING]
> This modifies a system app on your infotainment unit. The installer verifies everything before it touches `/system` and keeps a byte-for-byte backup, but you use it at your own risk. Not affiliated with Hyundai, Kia or Google.

**Status:** installed and running on a 2023 Ioniq 5 US (`NEEV.USA.0000.V015.012.260507`) with HMG Leafia Plus v1.0.5 and egmp-aa-ev-feat v0.2.1, at DPI 200 with `TAP_LIMIT=off`. Android Auto works at the new DPI. Whether the tap/scroll lockout is gone while driving is still being tested. On another unit, do the [dry run](#1-dry-run-over-adb-changes-nothing) first.

---

## Contents

- [Quick start](#quick-start)
- [What DPI does](#what-dpi-does)
- [How aa-proxy-rs sets DPI](#how-aa-proxy-rs-sets-dpi)
- [Where the DPI comes from on Gen5W](#where-the-dpi-comes-from-on-gen5w)
- [How the patch works](#how-the-patch-works)
- [Tap/scroll limit (`TAP_LIMIT=off`)](#tapscroll-limit-tap_limitoff)
- [Repo layout](#repo-layout)
- [Requirements](#requirements)
- [Build](#build)
- [1. Dry run over ADB](#1-dry-run-over-adb-changes-nothing)
- [2. Install](#2-install)
- [Changing the DPI later](#changing-the-dpi-later)
- [Uninstall](#uninstall)
- [Install order with egmp-aa-ev-feat / Leafia](#install-order-with-egmp-aa-ev-feat--leafia)
- [Package internals](#package-internals)
- [Troubleshooting](#troubleshooting)
- [Not done: changing DPI at runtime](#not-done-changing-dpi-at-runtime)
- [Credits](#credits)

---

## Quick start

```sh
python build.py                 # -> dist/hmg-aa-dpi-usb.zip
adb connect <head-unit-ip>:5555
python dryrun.py 200            # read-only check on the car
# then: copy the contents of dist/hmg-aa-dpi-usb.zip to a USB drive,
# set DPI= (and optionally TAP_LIMIT=off) in aa-dpi.txt, plug into the car, tap Yes in NEMESIS
```

## What DPI does

Android lays out UI in density-independent pixels: 1 dp = DPI / 160 physical pixels.

| DPI | 1 dp = | UI elements vs stock |
|---|---|---|
| 240 (**stock**, Ioniq 5 wide screen) | 1.5 px | 100% |
| 200 | 1.25 px | ~83% |
| 180 | 1.125 px | 75% |
| 160 | 1 px | ~67% |
| 130 | 0.81 px | ~54% |

**Lower DPI = smaller elements, more content.** Higher than 240 = bigger. Touch targets shrink as well, and AA may switch to a different layout because the screen looks wider in dp. 200 is a sensible first step from stock.

## How aa-proxy-rs sets DPI

aa-proxy-rs runs as a man-in-the-middle on the AA link. When the head unit sends its `ServiceDiscoveryResponse` (its list of displays and video configurations), `src/mitm.rs` finds the MAIN display's media sink and overwrites `density` and `real_density` in every `VideoConfiguration` with the configured `dpi`:

```rust
// Global DPI is a coarse legacy override for the MAIN AA display only.
if cfg.dpi > 0 {
    ... video_cfg.set_density(cfg.dpi.into());
        video_cfg.set_real_density(cfg.dpi.into());
}
```

The phone then lays out the AA UI for that density.

## Where the DPI comes from on Gen5W

On Gen5W those values are hardcoded in the Java projection app, `/system/app/HKMC_GPM.apk`. `GalConnectionSession.initGalReceiver()` calls

```
VideoSink.nearestVideoConfiguration(width, height, density, realDensity, fps, decoderDepth)
```

once per supported configuration. That wraps an 8-argument overload that builds `Protos.VideoConfiguration` with `setDensity()` / `setRealDensity()`, and the native receiver (`libautoreceiver_infobank.so`) serialises the result into the ServiceDiscoveryResponse. Which calls run depends on the screen model. The projection-tbt GPM has 12 of them:

| config | fps | density | real_density |
|---|---|---|---|
| 1240x720 | 60 | 240 | 167 / 200 |
| 1920x720 | 60 | 240 | 167 / 200 |
| 1280x480 | 60 | 160 | 111 / 134 |
| 800x465 | 60 / 30 | 160 | 108 / 129 |

So **stock DPI on the Ioniq 5's 12.3" wide screen is 240**. The dry run prints the exact values on your unit.

In bytecode each call is:

```
const/16 v1, W
const/16 v2, H
const/16 v3, DENSITY        <- rewritten
const/16 v4, REAL_DENSITY   <- rewritten
const/16 v5, FPS
const/4  v6, DEPTH
invoke-virtual/range {v0 .. v6}, VideoSink;->nearestVideoConfiguration(IIIIII)V
```

## How the patch works

`tool/src/AaDpi.java` is a small, dependency-free Java program that runs on the head unit's own Dalvik VM (`/system/bin/dalvikvm`, Android 4.4) and on any desktop JVM:

1. Finds `classes.dex` in the APK's zip central directory. It must be **stored** (uncompressed), which is how Leafia and egmp-aa-ev-feat build their GPM (`lpatch zipadd`).
2. Resolves the method id of `VideoSink;->nearestVideoConfiguration` with shorty `VIIIIII` from the dex tables.
3. Finds every instruction sequence above that invokes that method, so it works on any GPM build (stock layout, Leafia, egmp) whatever its index numbers.
4. Rewrites the density and real_density literals in place (2 bytes each). The file size doesn't change.
5. Recomputes the dex SHA-1 signature and Adler-32 checksum, and the classes.dex CRC-32 in both the zip local header and the central directory.

Nothing else changes. `test/check_patch.py` checks this independently: valid zip CRCs, valid dex checksum and signature, and every changed byte is a density literal or one of those checksum fields. On the projection-tbt APK: 12 sites, 56 bytes changed.

If the patcher finds no sites, a compressed dex, a bad checksum or anything else unexpected, it refuses and the install changes nothing.

The package ships **no Hyundai or Google files**, only the patcher (`aadpi.jar`, about 6 KB) and shell scripts. The patch is made on the car from the car's own APK.

```
AaDpi scan  <apk>                                 # list sites + tap limit state, verify checksums
AaDpi patch <src.apk> <dst.apk> <dpi> [<real>|keep] [notap]
```

`real` defaults to the same value as `dpi` (what aa-proxy-rs does). `keep` leaves the head unit's real_density values. DPI must be 60–480. `notap` also removes the tap/scroll limit (next section).

## Tap/scroll limit (`TAP_LIMIT=off`)

While the car moves, AA counts taps and scrolls and locks the screen for a while after too many. aa-proxy-rs's `remove_tap_restriction` stops this by deleting `SENSOR_SPEED` from the sensor list in the head unit's ServiceDiscoveryResponse (`src/mitm.rs`). The phone then doesn't know the car reports speed and doesn't apply the limit. Driving status still goes to the phone, so AA's normal driving restrictions remain. aa-proxy-rs notes it "may not work, depending on phone and Android version", and the same applies here.

In GPM the sensors it declares, and later sends, are the ones its providers put into a set. The driving-data provider (`sink/b/l.discoverSensorsImpl`, obfuscated `a(Set)`) adds three:

```
sget v0, SensorSource;->SENSOR_TYPE_SPEED          <- field index rewritten to DRIVING_STATUS
invoke-static {v0}, Integer;->valueOf(I)
move-result-object v0
invoke-interface {v3, v0}, Set;->add(Object)
sget v0, SensorSource;->SENSOR_TYPE_DRIVING_STATUS ; ... Set;->add
sget v0, SensorSource;->SENSOR_TYPE_NIGHT_MODE     ; ... Set;->add
```

With `notap`, the patcher points the first `sget` at `SENSOR_TYPE_DRIVING_STATUS`. That's one 2-byte field index, and the size doesn't change. The set ignores the duplicate, so SPEED is neither declared to the phone nor sent (the dispatcher only reports sensors in the set). The patcher finds the site by its shape and the resolved field and method names, and refuses if it doesn't find exactly one. `check_patch.py ... notap` verifies it independently. On the egmp GPM that's 1 more changed byte (55 at DPI 200).

egmp-aa-ev-feat doesn't use the speed sensor: its EV model, preconditioning and logs read the car directly.

## Repo layout

```
README.md               this file
build.py                builds tool/build/aadpi.jar, dist/aa.dpi.zip, dist/hmg-aa-dpi-usb.zip
dryrun.py               read-only check on a head unit over ADB
tool/src/AaDpi.java     the patcher
test/check_patch.py     independent verification of a patched APK
package/                the NEMESIS package tree (zipped into aa.dpi.zip)
  NEMESIS.data          id=aa.dpi, pre/post/preuninstall hooks, status app
  files/dpi.conf        default DPI=160 / REAL_DPI= / TAP_LIMIT=on
  scripts/common.sh     shared helpers (config, snapshot, swap, dexopt)
  scripts/pre.sh        preinstall: read config, patch into /data/nemesis/build/aa.dpi, verify
  scripts/post.sh       postinstall: snapshot live GPM, swap, dexopt, reboot
  scripts/preun.sh      preuninstall: restore snapshot if the live GPM is still ours
  bin/status.sh         NEMESIS Manager "launch": state + live densities + log
release/                USB drive root
  NEMESIS.data          type=install path=packages/aa.dpi.zip
  aa-dpi.txt            DPI setting read at install time
```

`dist/`, `tool/build/` and any `*.apk/*.odex/*.dex` are gitignored. `.gitattributes` forces LF line endings, because the head unit's shell can't run CRLF scripts (`build.py` also refuses to package them).

## Requirements

**Laptop**
- Python 3.8+
- JDK 8 or newer (`javac` on PATH)
- Android SDK **build-tools** (for `d8`) and **platform-tools** (for `adb`). The scripts look in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, `~/Android/Sdk`, `~/Library/Android/sdk` (macOS) and `~/AppData/Local/Android/Sdk` (Windows), or set `D8=` / `ADB=` explicitly.

**Head unit**
- Gen5W with [NEMESIS](https://github.com/xwtk/hmg_nemesis) installed
- A GPM whose `classes.dex` is stored in the APK. This is true with [HMG Leafia Plus](https://github.com/VysseCodes/HMG-Leafia-Plus) and/or egmp-aa-ev-feat installed. A stock odex-only GPM has no `classes.dex` in the APK, and the patcher refuses it.
- ADB to the unit for the dry run (e.g. NEMESIS `adb.tcp`, or egmp's `adb.home` on home Wi-Fi, port 5555)

## Build

```sh
python build.py
```

Produces:
- `tool/build/aadpi.jar`: the patcher as a dex jar (dex 035, `--min-api 18`)
- `dist/aa.dpi.zip`: the NEMESIS package
- `dist/hmg-aa-dpi-usb.zip`: copy its **contents** to a USB drive

Desktop self-test against any GPM APK you have:

```sh
javac --release 8 -d tool/build/classes tool/src/AaDpi.java
java -cp tool/build/classes AaDpi scan path/to/HKMC_GPM.apk
java -cp tool/build/classes AaDpi patch path/to/HKMC_GPM.apk /tmp/out.apk 200
python test/check_patch.py path/to/HKMC_GPM.apk /tmp/out.apk 200
```

## 1. Dry run over ADB (changes nothing)

With the car on and ADB connected:

```sh
adb connect <head-unit-ip>:5555
python dryrun.py 200          # or: python dryrun.py 160 keep, or: python dryrun.py 200 200 notap
```

It:
1. prints firmware, Android version, `dalvikvm` presence, and live GPM apk/odex md5s
2. pushes `aadpi.jar` to `/data/local/tmp/aa-dpi-dryrun` and runs `scan` on `/system/app/HKMC_GPM.apk` **with the car's own VM**. This lists the stock densities your unit advertises.
3. patches a **copy** into `/data/local/tmp` and scans it on the unit
4. pulls the original and the copy to `dist/dryrun/` and runs `check_patch.py` on them
5. removes `/data/local/tmp/aa-dpi-dryrun` (also on failure)

Expected end: `DRY RUN OK`. A `FAIL:` line names the step that failed. `/system` is only read.

`dist/dryrun/` then holds **your car's own GPM APK**. Don't share or commit it (it's gitignored).

## 2. Install

1. Copy the **contents** of `dist/hmg-aa-dpi-usb.zip` to an empty FAT32/exFAT drive:
   ```
   NEMESIS.data
   aa-dpi.txt
   packages/aa.dpi.zip
   ```
2. Edit `aa-dpi.txt`:
   ```
   DPI=200
   REAL_DPI=        # empty = same as DPI; or a number; or keep
   TAP_LIMIT=on     # off = no tap/scroll lockout while driving
   ```
3. Car on, plug the drive into a USB data port, tap **Yes** when NEMESIS asks.
4. It patches, runs dexopt and **reboots the head unit**. Remove the drive while it restarts. The installer renames `NEMESIS.data` to `NEMESIS.data.installed` so a drive left in doesn't loop.
5. Open NEMESIS Manager (NAV ×3) → `aa.dpi` → Launch to see the state and the densities the live GPM now advertises.

## Changing the DPI later

The value is fixed at install time. To change it, install again with a new value. The update runs the old uninstall first (which restores the original GPM) and then patches it at the new value, so changes never stack.

**By USB:** edit `aa-dpi.txt` on the drive, rename `NEMESIS.data.installed` back to `NEMESIS.data`, and plug it in. If a drive with an `aa-dpi.txt` in its top folder is plugged in during any install, that file wins over the zip's `files/dpi.conf`.

**By ADB:** set `DPI=` (and `TAP_LIMIT=`) in `package/files/dpi.conf`, then:
```sh
python build.py
adb push dist/aa.dpi.zip /data/local/tmp/
adb shell "nemesis root -c 'nemesis install --update /data/local/tmp/aa.dpi.zip'"
```
(The `nemesis root -c` wrapper is there because the plain ADB shell user may not be allowed to install packages.) The head unit reboots at the end.

Editing `/data/nemesis/apps/aa.dpi/files/dpi.conf` on the unit does nothing. The installer reads the config from the zip being installed.

## Uninstall

NEMESIS Manager → `aa.dpi` → Uninstall, then reboot. Or `nemesis uninstall aa.dpi`.

The snapshot (`/data/nemesis/backup/aa.dpi/`) is restored byte for byte, **but only if the live GPM is still the one aa.dpi wrote**. If another package replaced GPM in the meantime, its file is left alone and the stale snapshot is deleted.

## Install order with egmp-aa-ev-feat / Leafia

All three replace `HKMC_GPM.apk`:

| Situation | What to do |
|---|---|
| Installing aa.dpi | Install it **last**, after Leafia and egmp |
| Fresh egmp install while aa.dpi is active | Uninstall aa.dpi first. egmp only accepts Leafia's exact APK. |
| Updating egmp or Leafia | Go ahead. It replaces GPM and the DPI change is dropped. **Reinstall aa.dpi afterwards.** |
| Uninstalling egmp | Fine. It restores Leafia's GPM, dropping the DPI change. aa.dpi won't restore over it. |

The Manager status screen says `NOT active` when another package has replaced GPM under aa.dpi.

## Package internals

**preinstall** (`scripts/pre.sh`, runs from the staging dir):
- checks for `nemesis`, `dalvikvm`, `aadpi.jar` and `dpi.conf`
- reads the config (`files/dpi.conf`, overridden by `aa-dpi.txt` on a mounted USB drive), validates the numbers, and strips CR/whitespace with shell parameter expansion (KitKat toolbox has no `tr`)
- source APK: the snapshot, if the live GPM is already ours (reinstall); otherwise the live GPM
- `dalvikvm ... AaDpi patch` into `/data/nemesis/build/aa.dpi/`, then `AaDpi scan` the result, and records its md5
- any failure → pop-up, exit 1, nothing changed

**postinstall** (`scripts/post.sh`):
- re-checks the payload md5
- `pm disable` GPM; snapshots the live APK and odex on a fresh install
- `nemesis remount rw`; copy, compare, then rename the APK over the live one; records `ours.md5`
- deletes the odex, `dexopt --preopt`, wipes and prefills the dalvik cache (the same method Leafia and egmp use)
- remount ro, `pm enable`, retires the USB descriptor, pop-up, reboot

**preuninstall** (`scripts/preun.sh`): restores the APK and odex only if the live APK md5 equals `ours.md5`, then wipes the dalvik cache.

Files on the unit:
```
/data/nemesis/apps/aa.dpi/        installed package
/data/nemesis/backup/aa.dpi/      HKMC_GPM.apk, HKMC_GPM.odex, ours.md5
/data/nemesis/aa.dpi.log          install/uninstall log
```

## Troubleshooting

| Symptom | Look at / do |
|---|---|
| Pop-up "not supported" | `/data/nemesis/aa.dpi.log`: the scan found no sites or a compressed dex. Run the dry run and send its output. |
| Pop-up "bad DPI or TAP_LIMIT setting" | `aa-dpi.txt` / `dpi.conf`: `DPI=` must be a number (60–480), `TAP_LIMIT=` `on` or `off` |
| Tap/scroll lockout still appears with `TAP_LIMIT=off` | Manager status should say `tap limit: off`. If it does, the phone's AA version enforces it anyway (aa-proxy-rs has the same caveat). |
| AA doesn't start after install | Uninstall aa.dpi, reboot. Then check the log for dexopt errors. |
| Touch is offset / UI scaled oddly | Reinstall with `REAL_DPI=keep` |
| Status shows `NOT active` | Another package replaced GPM. Reinstall aa.dpi. |
| Reboot loop with the drive in | Remove the drive. Its `NEMESIS.data` should have been renamed. |

## Not done: changing DPI at runtime

Researched, not built. The 6-argument `nearestVideoConfiguration` wrapper is 45 code units. It has two near-identical branches that could be merged, freeing room to insert `SystemProperties.getInt("density", p3)` (and the same for p4). GPM's dex already references `SystemProperties.getInt(String,int)` (method id 257 in projection-tbt) and contains the string `"density"` (string id 6118). The rewrite would stay the same size, padded with `nop`s.

That would allow `setprop density 140` and reconnecting the phone, with no reinstall. The catches: `density` isn't a `persist.*` property, so a boot service would need to re-apply it, and a dialog app would need NEMESIS root to `setprop`. Dropped for now in favour of the install-time value.

## Credits

- [aa-proxy-rs](https://github.com/aa-proxy/aa-proxy-rs): the DPI override and `remove_tap_restriction` this mirrors
- [NEMESIS](https://github.com/xwtk/hmg_nemesis) (xwtk): package system, root, and the reference GPM used for testing
- [HMG Leafia Plus](https://github.com/VysseCodes/HMG-Leafia-Plus) and [egmp-aa-ev-feat](https://github.com/willemcvu/egmp-aa-ev-feat): the GPM install method (stored dex, dexopt, dalvik prefill, snapshot/restore)
