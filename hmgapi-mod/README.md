# aa-dpi as an HMG-API mod

Android Auto's DPI, its tap/scroll limit while driving and its video window (a smoother
picture), as a mod for
[HMG-API](https://github.com/VysseCodes/HMG-API) (the successor of HMG Leafia Plus).
They're set on HMG-API's settings page for the mod; there's no app of its own. Nothing
on the head unit is changed: HMG-API hooks the Android Auto app (GPM) while it runs,
instead of the NEMESIS package's patched GPM APK.

> [!WARNING]
> The video window is measured on a US Ioniq 5 (260507, wireless Android Auto). The DPI
> and the tap/scroll limit are checked off the car only (`test/run.sh`).

## In the car

1. Open the HMG-API app, then the mod (**Android Auto DPI**) and its settings.
2. Set the DPI (240 is the car's own; 200 is a good first step), choose the real
   density, turn the tap/scroll limit on or off, and set the video window (8 is the
   default; the car's own is 4).
3. Reconnect the phone: unplug and plug in, or turn its Wi-Fi off and on. The phone
   asks for the DPI, the car's sensors and the video window only when it connects, so a change shows at
   the next connection. No head-unit restart, no reinstall.

| Setting | What it does |
|---|---|
| `dpi` (60-480, default 200) | the DPI every video setting offers the phone (`gpm.video_sink.nearest`) |
| `real_dpi` (`same` / `keep`) | real density the same as the DPI (aa-proxy-rs's way, the default), or the car's own |
| `tap_limit` (on = stock) | off: the speed sensor isn't offered to the phone (`gpm.sensor_source.init`), so Android Auto doesn't lock taps and scrolling on the move; driving status still goes to the phone |
| `video_window` (1-16, default 8; 4 = stock) | how many video frames the phone may send before the car acknowledges them (see below) |

### The video window: a smoother picture

The car offers the phone 60 fps (on the wide screens, 1920×720 sent as 1920×1080 with margins),
but lets it have only 4 video frames unacknowledged: `VideoSink.init` sets
`nativeSetMaxUnackedFrames(4)`. Over Wi-Fi the round trip (receive, decode, show,
acknowledge) is long enough that the phone keeps waiting. On a US Ioniq 5 with wireless
Android Auto, measured with `dumpsys SurfaceFlinger --latency SurfaceView`:

| Window | Frame rate | Longest gap between frames | Video from the phone |
|---|---|---|---|
| 4 (the car's) | 41-43 fps | 50-67 ms | 4.3 Mbit/s |
| 8 | 56-59 fps | 33 ms | 15.5 Mbit/s |

The mod sets the window again from the same video hook, once per connection: `VideoSink.init`
runs before the connection's video settings, and the window goes to the phone only when it
opens the video channel. `nativeSetMaxUnackedFrames` is a JNI method of Android Auto's receiver
library, which is the same build on every Gen5W car, so its name doesn't change. More frames in
flight can add a little latency to taps (up to about 4 frames, 70 ms, at 60 fps): lower the
setting if Android Auto feels slow to respond, or set 4 for the car's own.

## How it's built

| Part | What it is |
|---|---|
| `mod.json` | id `aa-dpi`; hooks on `gpm.video_sink.nearest` and `gpm.sensor_source.init` (both `change`); `live` (loads when turned on, no restart); any car HMG-API has a map for |
| `hooks/` (`hooks.jar`) | `DpiHooks`: reads the settings each time Android Auto connects, so a saved change needs no restart; `Dpi`: the arithmetic |
| `settings.json` | the four settings, with their defaults: HMG-API shows them on the mod's settings page |

Another mod that sets Android Auto's density through HMG-API itself (`projection.aa_density`) would change the same value; turn one of them off. egmp-aa-ev's HMG-API mod also changes the sensor list (it adds the EV sensor), and the two combine.

## Build and test

Needs a JDK, the Android SDK (build-tools and a platform `android.jar`; `ANDROID_HOME`)
and an HMG-API checkout (`HMGAPI`, default `../HMG-API`). No car files.

```bash
HMGAPI=../HMG-API sh hmgapi-mod/build.sh
```

```bash
HMGAPI=../HMG-API sh hmgapi-mod/test/run.sh
```

The first gives `build/hmgapi/mod/aa-dpi/`. With your HMG-API author key, the build
also signs the package, `dist/aa-dpi-<version>.zip`:

```bash
java -cp ../HMG-API/out/engine-host hmgapi.engine.Signing keygen ~/hmg-keys/<name>.key
```

```bash
HMGAPI=../HMG-API sh hmgapi-mod/build.sh ~/hmg-keys/<name>.key
```

## Install

1. Uninstall the NEMESIS package `aa.dpi` first (NEMESIS Manager → `aa.dpi` → uninstall,
   reboot): it patches GPM's file, which HMG-API expects stock.
2. HMG-API 1.0.0 or newer. Its hooks run on a car whose map is checked on a car:
   in the HMG-API app's **Settings**, tap **Check the map on this car** (hooks run once it
   passes and the head unit restarts), or turn on **Try unchecked maps**. No adb needed.
3. Download `aa-dpi-<version>.zip` from the repo's Releases (or build it, above), put it
   in `HMGAPI/updates/` on a USB stick, then **Check USB updates** in the HMG-API app (or
   install it over adb). Until the author key is on HMG-API's trusted list
   (`maps/authors.json`), HMG-API installs it with a warning.

In HMG-API's log, `[aa-dpi]` lines show each connection's DPI and tap limit.

## Releasing

Releases are built by CI, from a release created in GitHub's UI
(`.github/workflows/release.yml`):

1. Set `"version"` in `hmgapi-mod/mod.json` and merge it to `main`.
2. In GitHub: **Releases → Draft a new release**, tag `v<version>`, publish.
3. CI checks the tag matches `mod.json`, checks out HMG-API (`HMGAPI_REF` in the
   workflow, a release tag), runs `test/run.sh`, builds the mod, signs it with the key
   below and attaches `aa-dpi-<version>.zip` to the release, with its NEMESIS packages
   (HMG-API's `tools/mknemesismod.sh`): `aa-dpi-<version>-nemesis.zip` for a USB stick
   and `aa-dpi-<version>-nemesis-package.zip` for the NEMESIS Package Store. A failed
   check leaves the release without them; fix it and re-run the workflow (Actions →
   Release → Run workflow, with the tag).

The repository secret it needs (Settings → Secrets and variables → Actions):

| Secret | What |
|---|---|
| `HMGAPI_AUTHOR_KEY` | the contents of your HMG-API author key file (`Signing keygen`, one line; CI derives the `.pub` from it): signs the mod package. HMG-API only updates a mod from the key that installed it. |

Keep the key file backed up outside GitHub too: secrets can't be read back.

