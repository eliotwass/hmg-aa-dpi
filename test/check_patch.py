#!/usr/bin/env python3
"""Check an AaDpi-patched APK against its source, independently of AaDpi.

Usage: check_patch.py <src.apk> <patched.apk> <dpi> [<real_dpi>|keep] [notap]

Passes only if:
  - the zip is valid (every entry's CRC matches) and the same size,
  - classes.dex has a valid adler32 checksum and SHA-1 signature,
  - every changed byte is a density/real_density literal, the dex header
    checksum/signature, one of the two classes.dex CRC fields, or (notap) the
    field index of the one `sget SENSOR_TYPE_SPEED` that feeds Set.add,
  - every nearestVideoConfiguration(IIIIII)V site now carries the new values,
  - with notap, that sget now reads SENSOR_TYPE_DRIVING_STATUS; without it,
    the sensor code is untouched.
"""

import hashlib
import re
import struct
import sys
import zipfile
import zlib

# sget vA, F ; invoke-static {vA}, valueOf ; move-result-object vA ; invoke-interface {vS, vA}, add
SET_ADD = re.compile(rb"(?=\x60([\x00-\x0f])(..)\x71\x10..\1\x00\x0c\1\x72\x20...\x00)", re.S)
SITE = re.compile(rb"\x13\x01..\x13\x02..\x13\x03(..)\x13\x04(..)\x13\x05..\x12[\x06\x16\x26\x36\x46\x56\x66\x76]\x74\x07..\x00\x00", re.S)


def dex_of(path):
    with zipfile.ZipFile(path) as z:
        bad = z.testzip()
        assert bad is None, f"{path}: bad CRC in {bad}"
        info = z.getinfo("classes.dex")
        assert info.compress_type == zipfile.ZIP_STORED
        return z.read("classes.dex"), info


def sensor_fields(d):
    """field ids of SensorSource.SENSOR_TYPE_SPEED / _DRIVING_STATUS"""
    u32 = lambda o: struct.unpack_from("<I", d, o)[0]

    def string(i):
        p = u32(u32(60) + 4 * i)
        while d[p] & 0x80:
            p += 1
        return d[p + 1:d.index(b"\0", p + 1)].decode()

    out = {}
    for i in range(u32(80)):
        cls, _, name = struct.unpack_from("<HHI", d, u32(84) + 8 * i)
        if string(u32(u32(68) + 4 * cls)) == "Lcom/google/android/projection/protocol/SensorSource;":
            out[string(name)] = i
    return out["SENSOR_TYPE_SPEED"], out["SENSOR_TYPE_DRIVING_STATUS"]


def speed_sites(d):
    """offsets of `sget SPEED` -> Set.add directly followed by the same for DRIVING_STATUS"""
    speed, status = sensor_fields(d)
    adds = {m.start(): struct.unpack_from("<H", m.group(2))[0]
            for m in SET_ADD.finditer(d) if m.start() % 2 == 0}
    return [o for o, f in adds.items() if f == speed and adds.get(o + 18) == status], status


def main():
    args = sys.argv[1:]
    notap = args[-1] == "notap"
    if notap:
        args = args[:-1]
    src, dst, dpi = args[0], args[1], int(args[2])
    real = args[3] if len(args) > 3 else str(dpi)
    a, b = open(src, "rb").read(), open(dst, "rb").read()
    assert len(a) == len(b), "size changed"

    d0, info = dex_of(src)
    d1, _ = dex_of(dst)
    assert struct.unpack_from("<I", d1, 8)[0] == zlib.adler32(d1[12:]), "dex checksum"
    assert d1[12:32] == hashlib.sha1(d1[32:]).digest(), "dex signature"

    sites = [m.start() for m in SITE.finditer(d0)]
    assert sites, "no sites in source"
    for off in sites:
        dens, rd = struct.unpack_from("<hh", d1, off + 10)[0], struct.unpack_from("<h", d1, off + 14)[0]
        assert dens == dpi, f"site {off:#x} density {dens}"
        want_rd = struct.unpack_from("<h", d0, off + 14)[0] if real == "keep" else int(real)
        assert rd == want_rd, f"site {off:#x} real_density {rd}"

    if notap:
        tap, status = speed_sites(d0)
        assert len(tap) == 1, f"want one speed sensor site in source, found {len(tap)}"
        got = struct.unpack_from("<H", d1, tap[0] + 2)[0]
        assert got == status, f"speed sensor site {tap[0]:#x} reads field {got}, not DRIVING_STATUS"

    # allowed changes, as offsets in the APK
    with open(src, "rb") as f:
        f.seek(info.header_offset)
        lh = f.read(30)
    data = info.header_offset + 30 + struct.unpack_from("<H", lh, 26)[0] + struct.unpack_from("<H", lh, 28)[0]
    allowed = set(range(data + 8, data + 32))
    for off in sites:
        allowed |= set(range(data + off + 10, data + off + 12)) | set(range(data + off + 14, data + off + 16))
    if notap:
        allowed |= set(range(data + tap[0] + 2, data + tap[0] + 4))
    allowed |= set(range(info.header_offset + 14, info.header_offset + 18))
    eocd = a.rfind(b"PK\x05\x06")
    cdoff = struct.unpack_from("<I", a, eocd + 16)[0]
    p = cdoff
    while a[p:p + 4] == b"PK\x01\x02":
        n, x, c = struct.unpack_from("<HHH", a, p + 28)
        if a[p + 46:p + 46 + n] == b"classes.dex":
            allowed |= set(range(p + 16, p + 20))
        p += 46 + n + x + c
    diffs = [i for i in range(len(a)) if a[i] != b[i]]
    stray = [i for i in diffs if i not in allowed]
    assert not stray, f"unexpected changes at {[hex(i) for i in stray[:10]]}"
    print(f"OK: {len(sites)} sites{', tap limit off' if notap else ''}, {len(diffs)} bytes changed, all expected")


if __name__ == "__main__":
    main()
