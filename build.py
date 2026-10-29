#!/usr/bin/env python3
"""Build the aa.dpi NEMESIS package and its USB-drive release zip.

  python build.py            -> dist/aa.dpi.zip, dist/hmg-aa-dpi-usb.zip

Needs javac (JDK 8+) and d8 from the Android SDK build-tools (found through
$D8, $ANDROID_HOME / $ANDROID_SDK_ROOT, or the default SDK location).
"""

import glob
import os
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent
BUILD = ROOT / "tool" / "build"
DIST = ROOT / "dist"
WIN = os.name == "nt"


def find_d8():
    if os.environ.get("D8"):
        return os.environ["D8"]
    sdks = [os.environ.get("ANDROID_HOME"), os.environ.get("ANDROID_SDK_ROOT"),
            os.path.expanduser("~/AppData/Local/Android/Sdk"), os.path.expanduser("~/Android/Sdk"),
            os.path.expanduser("~/Library/Android/sdk")]
    for sdk in filter(None, sdks):
        hits = sorted(glob.glob(os.path.join(sdk, "build-tools", "*", "d8.bat" if WIN else "d8")))
        if hits:
            return hits[-1]
    sys.exit("d8 not found: set D8 or ANDROID_HOME")


def run(*cmd):
    print("+", " ".join(map(str, cmd)))
    subprocess.run([str(c) for c in cmd], check=True)


def add(z, path, arc):
    data = path.read_bytes()
    if path.suffix in (".sh", ".data", ".conf", ".txt") and b"\r" in data:
        sys.exit(f"{path} has CRLF line endings")
    info = zipfile.ZipInfo(arc, date_time=(2026, 10, 29, 0, 0, 0))
    info.external_attr = (0o755 if path.suffix == ".sh" else 0o644) << 16
    info.compress_type = zipfile.ZIP_DEFLATED
    z.writestr(info, data)


def main():
    shutil.rmtree(BUILD, ignore_errors=True)
    (BUILD / "classes").mkdir(parents=True)
    run("javac", "--release", "8", "-Xlint:-options", "-d", BUILD / "classes", ROOT / "tool/src/AaDpi.java")
    classes = sorted((BUILD / "classes").glob("*.class"))
    run(find_d8(), "--release", "--min-api", "18", "--output", BUILD / "aadpi.jar", *classes)

    DIST.mkdir(exist_ok=True)
    pkg = DIST / "aa.dpi.zip"
    pkg_dir = ROOT / "package"
    with zipfile.ZipFile(pkg, "w") as z:
        for p in sorted(pkg_dir.rglob("*")):
            if p.is_file():
                add(z, p, p.relative_to(pkg_dir).as_posix())
        add(z, BUILD / "aadpi.jar", "files/aadpi.jar")
    print("built", pkg)

    usb = DIST / "hmg-aa-dpi-usb.zip"
    with zipfile.ZipFile(usb, "w") as z:
        add(z, ROOT / "release/NEMESIS.data", "NEMESIS.data")
        add(z, ROOT / "release/aa-dpi.txt", "aa-dpi.txt")
        add(z, pkg, "packages/aa.dpi.zip")
    print("built", usb)


if __name__ == "__main__":
    main()
