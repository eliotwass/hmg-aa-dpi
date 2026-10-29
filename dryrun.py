#!/usr/bin/env python3
"""Dry run of aa.dpi on a head unit over ADB. Changes nothing on /system.

  python dryrun.py [dpi] [real_dpi|keep] [notap]   (default 200, same as dpi)

notap also removes the tap/scroll limit (TAP_LIMIT=off).

1. checks the unit: dalvikvm present, live GPM apk/odex md5s
2. pushes the patcher to /data/local/tmp/aa-dpi-dryrun and runs
   `AaDpi scan` on the live /system/app/HKMC_GPM.apk with the unit's own VM
3. patches a copy into /data/local/tmp (the live file is only read)
4. pulls the original and the patched copy to dist/dryrun/ and verifies the
   result with test/check_patch.py
5. removes /data/local/tmp/aa-dpi-dryrun

Run `python build.py` first (it makes tool/build/aadpi.jar). dist/dryrun/
holds this unit's own GPM APK: keep it private.
"""

import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
JAR = ROOT / "tool" / "build" / "aadpi.jar"
OUT = ROOT / "dist" / "dryrun"
REMOTE = "/data/local/tmp/aa-dpi-dryrun"
GPM = "/system/app/HKMC_GPM.apk"


def find_adb():
    if os.environ.get("ADB"):
        return os.environ["ADB"]
    if shutil.which("adb"):
        return shutil.which("adb")
    for sdk in (os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
                os.path.expanduser("~/AppData/Local/Android/Sdk"), os.path.expanduser("~/Android/Sdk"),
                os.path.expanduser("~/Library/Android/sdk")):
        if sdk:
            p = Path(sdk) / "platform-tools" / ("adb.exe" if os.name == "nt" else "adb")
            if p.exists():
                return str(p)
    sys.exit("adb not found: set ADB or put it on PATH")


ADB = find_adb()


def adb(*args, check=True):
    r = subprocess.run([ADB, *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        sys.exit(f"adb {' '.join(args)} failed:\n{r.stdout}{r.stderr}")
    return r.stdout.replace("\r\n", "\n")


def sh(cmd):
    """Run on the unit; KitKat's adb shell drops exit codes, so echo one."""
    out = adb("shell", f"{cmd}; echo __rc=$?")
    body, _, rc = out.rpartition("__rc=")
    return int(rc.strip() or 1), body.rstrip("\n")


def step(title):
    print(f"\n== {title} ==")


def main():
    args = sys.argv[1:]
    notap = ["notap"] if args and args[-1] == "notap" else []
    args = args[:len(args) - len(notap)]
    dpi = args[0] if len(args) > 0 else "200"
    real = args[1] if len(args) > 1 else dpi
    if not JAR.exists():
        sys.exit(f"missing {JAR} - run python build.py first")

    step("device")
    state = adb("get-state", check=False).strip()
    if state != "device":
        sys.exit(f"no ADB device (state: {state or 'none'}); is adb.home / adb.tcp connected?")
    for prop in ("ro.product.device", "ro.build.display.id", "ro.build.version.release"):
        print(f"{prop}: {sh(f'getprop {prop}')[1]}")
    rc, out = sh("ls -l /system/bin/dalvikvm")
    print(out)
    if "dalvikvm" not in out:
        sys.exit("FAIL: /system/bin/dalvikvm missing - the package cannot run on this unit")
    print(sh(f"md5 {GPM} /system/app/HKMC_GPM.odex")[1])

    try:
        step("push patcher")
        sh(f"rm -rf {REMOTE}")
        rc, out = sh(f"mkdir -p {REMOTE}/vm/dalvik-cache")
        if rc:
            sys.exit(f"FAIL: mkdir {REMOTE}: {out}")
        adb("push", str(JAR), f"{REMOTE}/aadpi.jar")
        vm = f"ANDROID_DATA={REMOTE}/vm /system/bin/dalvikvm -Xmx64m -cp {REMOTE}/aadpi.jar AaDpi"

        step(f"scan live {GPM}")
        rc, out = sh(f"{vm} scan {GPM}")
        print(out)
        if rc:
            sys.exit("FAIL: scan did not pass - installing aa.dpi would refuse on this unit")

        step(f"patch a copy (density {dpi}, real_density {real}{', tap limit off' if notap else ''})")
        rc, out = sh(f"{vm} patch {GPM} {REMOTE}/HKMC_GPM.apk {dpi} {real} {' '.join(notap)}")
        print(out)
        if rc:
            sys.exit("FAIL: patch failed")
        rc, out = sh(f"{vm} scan {REMOTE}/HKMC_GPM.apk")
        print(out)
        if rc:
            sys.exit("FAIL: patched copy did not verify on the unit")

        step("verify on this machine")
        OUT.mkdir(parents=True, exist_ok=True)
        orig, patched = OUT / "HKMC_GPM.orig.apk", OUT / "HKMC_GPM.patched.apk"
        adb("pull", GPM, str(orig))
        adb("pull", f"{REMOTE}/HKMC_GPM.apk", str(patched))
        r = subprocess.run([sys.executable, "-I", str(ROOT / "test" / "check_patch.py"),
                            str(orig), str(patched), dpi, real, *notap])
        if r.returncode:
            sys.exit("FAIL: check_patch.py rejected the patched copy")
    finally:
        sh(f"rm -rf {REMOTE}")
        print(f"\n(cleaned up {REMOTE})")

    print("\nDRY RUN OK: this unit can run aa.dpi. Nothing on /system was changed.")
    print(f"Pulled files are in {OUT} (this unit's own GPM - keep them private).")


if __name__ == "__main__":
    main()
