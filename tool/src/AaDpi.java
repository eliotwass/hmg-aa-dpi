import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import java.util.zip.Adler32;
import java.util.zip.CRC32;

/**
 * Rewrites the Android Auto display density (DPI) that the Gen5W head unit's
 * HKMC_GPM.apk advertises to the phone.
 *
 * aa-proxy-rs does this by rewriting VideoConfiguration.density/real_density
 * in the ServiceDiscoveryResponse on the wire. On this head unit the values
 * come from hardcoded literals in GalConnectionSession.initGalReceiver():
 *
 *   const/16 v1, W ; const/16 v2, H ; const/16 v3, DENSITY ; const/16 v4, REAL
 *   const/16 v5, FPS ; const/4 v6, DEPTH
 *   invoke-virtual/range {v0..v6}, VideoSink;->nearestVideoConfiguration(IIIIII)V
 *
 * so the same effect is had by changing the DENSITY/REAL literals in place.
 *
 * Optionally (notap) it also removes the phone's tap/scroll limit while
 * driving, like aa-proxy-rs's remove_tap_restriction, which drops SENSOR_SPEED
 * from the ServiceDiscoveryResponse. Here the sensors GPM declares (and later
 * sends) are the ones its providers put in a set; DrivingDataSensors'
 * discoverSensorsImpl adds SPEED then DRIVING_STATUS:
 *
 *   sget v0, SensorSource;->SENSOR_TYPE_SPEED   <- field pointed at DRIVING_STATUS
 *   invoke-static {v0}, Integer;->valueOf(I) ; move-result-object v0
 *   invoke-interface {v3, v0}, Set;->add(Object)
 *   sget v0, SensorSource;->SENSOR_TYPE_DRIVING_STATUS ; ... Set;->add
 *
 * so DRIVING_STATUS is added twice and SPEED never.
 *
 * The edits are size-preserving: classes.dex must be STORED in the APK (as in
 * Leafia's and egmp-aa-ev-feat's GPM builds, made with lpatch zipadd). The dex
 * checksum and signature and both zip CRCs are recomputed.
 *
 * Runs on the head unit with dalvikvm (Android 4.4) and on a desktop JVM.
 *
 *   AaDpi scan  <apk>
 *   AaDpi patch <src.apk> <dst.apk> <dpi> [<real_dpi>|keep] [notap]
 */
public final class AaDpi {
    static final String CLASS = "Lcom/google/android/projection/protocol/VideoSink;";
    static final String METHOD = "nearestVideoConfiguration";
    static final String SHORTY = "VIIIIII";
    static final String SENSORS = "Lcom/google/android/projection/protocol/SensorSource;";
    static final int MIN_DPI = 60, MAX_DPI = 480;

    public static void main(String[] args) {
        try {
            if (args.length == 2 && args[0].equals("scan")) {
                System.exit(scan(args[1]));
            }
            boolean noTap = args.length > 0 && args[args.length - 1].equals("notap");
            int n = noTap ? args.length - 1 : args.length;
            if ((n == 4 || n == 5) && args[0].equals("patch")) {
                int dpi = parseDpi(args[3]);
                int real = n == 5
                        ? (args[4].equals("keep") ? -1 : parseDpi(args[4]))
                        : dpi;
                System.exit(patch(args[1], args[2], dpi, real, noTap));
            }
            System.err.println("usage: AaDpi scan <apk>\n"
                    + "       AaDpi patch <src.apk> <dst.apk> <dpi> [<real_dpi>|keep] [notap]");
            System.exit(2);
        } catch (Exception e) {
            System.out.println("FAIL: " + e.getMessage());
            System.exit(1);
        }
    }

    static int parseDpi(String s) {
        int v;
        try {
            v = Integer.parseInt(s.trim());
        } catch (NumberFormatException e) {
            throw new IllegalArgumentException("dpi '" + s + "' is not a number");
        }
        if (v < MIN_DPI || v > MAX_DPI) {
            throw new IllegalArgumentException("dpi " + v + " outside " + MIN_DPI + ".." + MAX_DPI);
        }
        return v;
    }

    // ---- zip: locate the stored classes.dex -------------------------------

    static final class Entry {
        long cdOff;    // central directory header
        long localOff; // local file header
        long dataOff;  // first byte of classes.dex
        int size;
        int crc;
    }

    static Entry findDex(RandomAccessFile f) throws IOException {
        long len = f.length();
        int tailLen = (int) Math.min(len, 22 + 65535);
        byte[] tail = new byte[tailLen];
        f.seek(len - tailLen);
        f.readFully(tail);
        int e = -1;
        for (int i = tailLen - 22; i >= 0; i--) {
            if (u32(tail, i) == 0x06054b50) {
                e = i;
                break;
            }
        }
        if (e < 0) throw new IOException("apk: no end of central directory");
        int count = u16(tail, e + 10);
        long cdSize = u32(tail, e + 12) & 0xffffffffL;
        long cdOff = u32(tail, e + 16) & 0xffffffffL;
        byte[] cd = new byte[(int) cdSize];
        f.seek(cdOff);
        f.readFully(cd);
        Entry found = null;
        for (int p = 0, k = 0; k < count; k++) {
            if (u32(cd, p) != 0x02014b50) throw new IOException("apk: bad central directory");
            int n = u16(cd, p + 28), x = u16(cd, p + 30), c = u16(cd, p + 32);
            if (n == 11 && new String(cd, p + 46, n, "US-ASCII").equals("classes.dex")) {
                if (found != null) throw new IOException("apk: two classes.dex entries");
                int method = u16(cd, p + 10);
                int csize = u32(cd, p + 20), usize = u32(cd, p + 24);
                if (method != 0 || csize != usize) {
                    throw new IOException("apk: classes.dex is compressed (method " + method
                            + "); only stored dex is supported");
                }
                found = new Entry();
                found.cdOff = cdOff + p;
                found.localOff = u32(cd, p + 42) & 0xffffffffL;
                found.size = usize;
                found.crc = u32(cd, p + 16);
            }
            p += 46 + n + x + c;
        }
        if (found == null) throw new IOException("apk: no classes.dex (odex-only APK?)");
        byte[] lh = new byte[30];
        f.seek(found.localOff);
        f.readFully(lh);
        if (u32(lh, 0) != 0x04034b50) throw new IOException("apk: bad local header");
        if ((u16(lh, 6) & 8) != 0) throw new IOException("apk: data descriptor not supported");
        if (u32(lh, 14) != found.crc) throw new IOException("apk: local/central CRC differ");
        found.dataOff = found.localOff + 30 + u16(lh, 26) + u16(lh, 28);
        return found;
    }

    // ---- dex: find the nearestVideoConfiguration(IIIIII)V call sites ------

    static final class Site {
        int off; // start of the const/16 v1 instruction
        int w, h, density, real, fps;
    }

    static String dexString(byte[] d, int idx) {
        int p = u32(d, u32(d, 60) + 4 * idx);
        while ((d[p] & 0x80) != 0) p++; // skip uleb128 utf16 length
        p++;
        int e = p;
        while (d[e] != 0) e++;
        try {
            return new String(d, p, e - p, "UTF-8");
        } catch (IOException ex) {
            throw new RuntimeException(ex);
        }
    }

    static Set<Integer> targetMethods(byte[] d) {
        int typeOff = u32(d, 68), protoOff = u32(d, 76);
        int methodCount = u32(d, 88), methodOff = u32(d, 92);
        Set<Integer> out = new HashSet<Integer>();
        for (int i = 0; i < methodCount; i++) {
            int m = methodOff + 8 * i;
            int name = u32(d, m + 4);
            if (!dexString(d, name).equals(METHOD)) continue;
            int cls = u32(d, typeOff + 4 * u16(d, m));
            if (!dexString(d, cls).equals(CLASS)) continue;
            int shorty = u32(d, protoOff + 12 * u16(d, m + 2));
            if (dexString(d, shorty).equals(SHORTY)) out.add(i);
        }
        return out;
    }

    static List<Site> findSites(byte[] d) throws IOException {
        if (d.length < 0x70 || d[0] != 'd' || d[1] != 'e' || d[2] != 'x' || d[3] != '\n') {
            throw new IOException("classes.dex: bad magic");
        }
        Set<Integer> targets = targetMethods(d);
        if (targets.isEmpty()) throw new IOException("dex has no " + CLASS + METHOD + "(IIIIII)V");
        List<Site> sites = new ArrayList<Site>();
        for (int i = 0x70; i + 28 <= d.length; i += 2) {
            if (d[i] != 0x13 || d[i + 1] != 1) continue;
            boolean ok = true;
            for (int r = 2; r <= 5 && ok; r++) {
                ok = d[i + 4 * (r - 1)] == 0x13 && d[i + 4 * (r - 1) + 1] == r;
            }
            if (!ok) continue;
            if (d[i + 20] != 0x12 || (d[i + 21] & 0x0f) != 6) continue;   // const/4 v6
            if ((d[i + 22] & 0xff) != 0x74 || d[i + 23] != 7) continue;    // invoke-virtual/range, 7 regs
            if (!targets.contains(u16(d, i + 24)) || u16(d, i + 26) != 0) continue; // {v0..v6}
            Site s = new Site();
            s.off = i;
            s.w = (short) u16(d, i + 2);
            s.h = (short) u16(d, i + 6);
            s.density = (short) u16(d, i + 10);
            s.real = (short) u16(d, i + 14);
            s.fps = (short) u16(d, i + 18);
            sites.add(s);
        }
        return sites;
    }

    static void printSites(List<Site> sites) {
        for (Site s : sites) {
            System.out.println("  site 0x" + Integer.toHexString(s.off) + ": " + s.w + "x" + s.h
                    + " @" + s.fps + "fps  density=" + s.density + " real_density=" + s.real);
        }
    }

    // ---- dex: the SENSOR_SPEED entry of the driving-data sensor set -------

    static final class TapSite {
        int off;         // start of the sget
        boolean removed; // already reads DRIVING_STATUS
    }

    static int fieldId(byte[] d, String cls, String name) {
        int typeOff = u32(d, 68), count = u32(d, 80), off = u32(d, 84);
        for (int i = 0; i < count; i++) {
            int f = off + 8 * i;
            if (dexString(d, u32(d, f + 4)).equals(name)
                    && dexString(d, u32(d, typeOff + 4 * u16(d, f))).equals(cls)) {
                return i;
            }
        }
        return -1;
    }

    static boolean methodIs(byte[] d, int idx, String cls, String name) {
        int m = u32(d, 92) + 8 * idx;
        return dexString(d, u32(d, m + 4)).equals(name)
                && dexString(d, u32(d, u32(d, 68) + 4 * u16(d, m))).equals(cls);
    }

    // sget vA, field ; invoke-static {vA}, Integer.valueOf(I) ;
    // move-result-object vA ; invoke-interface {vS, vA}, Set.add(Object):
    // returns the field index, or -1 if the code at i isn't that
    static int setAdd(byte[] d, int i) {
        if (d[i] != 0x60 || (d[i + 1] & 0xf0) != 0) return -1;
        int a = d[i + 1];
        if ((d[i + 4] & 0xff) != 0x71 || d[i + 5] != 0x10 || d[i + 8] != a || d[i + 9] != 0) return -1;
        if (d[i + 10] != 0x0c || d[i + 11] != a) return -1;
        if (d[i + 12] != 0x72 || d[i + 13] != 0x20 || (d[i + 16] >> 4 & 0x0f) != a || d[i + 17] != 0) return -1;
        if (!methodIs(d, u16(d, i + 6), "Ljava/lang/Integer;", "valueOf")) return -1;
        if (!methodIs(d, u16(d, i + 14), "Ljava/util/Set;", "add")) return -1;
        return u16(d, i + 2);
    }

    static TapSite findTapSite(byte[] d) throws IOException {
        int speed = fieldId(d, SENSORS, "SENSOR_TYPE_SPEED");
        int status = fieldId(d, SENSORS, "SENSOR_TYPE_DRIVING_STATUS");
        if (speed < 0 || status < 0) return null;
        TapSite found = null;
        for (int i = 0x70; i + 36 <= d.length; i += 2) {
            int f = setAdd(d, i);
            if (f != speed && f != status) continue;
            if (setAdd(d, i + 18) != status) continue;
            if (found != null) throw new IOException("two speed sensor sites; GPM layout unknown");
            found = new TapSite();
            found.off = i;
            found.removed = f == status;
        }
        return found;
    }

    static void printTapSite(TapSite t) {
        if (t == null) {
            System.out.println("tap limit: speed sensor site not found");
        } else {
            System.out.println("tap limit: " + (t.removed ? "off (speed sensor not declared)" : "stock (speed sensor declared)")
                    + ", site 0x" + Integer.toHexString(t.off));
        }
    }

    // ---- commands ----------------------------------------------------------

    static int scan(String apk) throws Exception {
        RandomAccessFile f = new RandomAccessFile(apk, "r");
        try {
            Entry e = findDex(f);
            byte[] d = new byte[e.size];
            f.seek(e.dataOff);
            f.readFully(d);
            boolean sumOk = adler(d) == u32(d, 8);
            boolean crcOk = crc(d) == e.crc;
            List<Site> sites = findSites(d);
            System.out.println("classes.dex: " + e.size + " bytes, checksum "
                    + (sumOk ? "ok" : "BAD") + ", zip crc " + (crcOk ? "ok" : "BAD")
                    + ", " + sites.size() + " video config sites");
            printSites(sites);
            printTapSite(findTapSite(d));
            return sumOk && crcOk && !sites.isEmpty() ? 0 : 1;
        } finally {
            f.close();
        }
    }

    static int patch(String src, String dst, int dpi, int real, boolean noTap) throws Exception {
        copy(src, dst);
        RandomAccessFile f = new RandomAccessFile(dst, "rw");
        try {
            Entry e = findDex(f);
            byte[] d = new byte[e.size];
            f.seek(e.dataOff);
            f.readFully(d);
            if (adler(d) != u32(d, 8)) throw new IOException("source dex checksum is bad");
            if (crc(d) != e.crc) throw new IOException("source zip crc is bad");
            List<Site> sites = findSites(d);
            if (sites.isEmpty()) throw new IOException("no video config sites found; GPM layout unknown");
            TapSite tap = findTapSite(d);
            if (noTap && tap == null) throw new IOException("no speed sensor site found; can't remove the tap limit on this GPM");
            System.out.println("before:");
            printSites(sites);
            printTapSite(tap);
            for (Site s : sites) {
                w16(d, s.off + 10, dpi);
                if (real > 0) w16(d, s.off + 14, real);
            }
            if (noTap) w16(d, tap.off + 2, fieldId(d, SENSORS, "SENSOR_TYPE_DRIVING_STATUS"));
            TapSite after = findTapSite(d);
            if (noTap && (after == null || !after.removed)) throw new IOException("tap limit patch did not take");
            MessageDigest sha = MessageDigest.getInstance("SHA-1");
            sha.update(d, 32, d.length - 32);
            System.arraycopy(sha.digest(), 0, d, 12, 20);
            w32(d, 8, adler(d));
            int newCrc = crc(d);

            f.seek(e.dataOff);
            f.write(d);
            byte[] c = new byte[4];
            w32(c, 0, newCrc);
            f.seek(e.localOff + 14);
            f.write(c);
            f.seek(e.cdOff + 16);
            f.write(c);
            System.out.println("after:");
            printSites(findSites(d));
            printTapSite(after);
            System.out.println("OK: " + sites.size() + " sites set to density " + dpi
                    + (real > 0 ? ", real_density " + real : ", real_density unchanged")
                    + (noTap ? ", tap limit off" : ""));
            return 0;
        } finally {
            f.close();
        }
    }

    // ---- helpers -----------------------------------------------------------

    static int adler(byte[] d) {
        Adler32 a = new Adler32();
        a.update(d, 12, d.length - 12);
        return (int) a.getValue();
    }

    static int crc(byte[] d) {
        CRC32 c = new CRC32();
        c.update(d, 0, d.length);
        return (int) c.getValue();
    }

    static void copy(String src, String dst) throws IOException {
        InputStream in = new FileInputStream(src);
        try {
            OutputStream out = new FileOutputStream(dst);
            try {
                byte[] buf = new byte[1 << 16];
                int n;
                while ((n = in.read(buf)) > 0) out.write(buf, 0, n);
            } finally {
                out.close();
            }
        } finally {
            in.close();
        }
    }

    static int u16(byte[] b, int o) {
        return (b[o] & 0xff) | (b[o + 1] & 0xff) << 8;
    }

    static int u32(byte[] b, int o) {
        return u16(b, o) | u16(b, o + 2) << 16;
    }

    static void w16(byte[] b, int o, int v) {
        b[o] = (byte) v;
        b[o + 1] = (byte) (v >> 8);
    }

    static void w32(byte[] b, int o, int v) {
        w16(b, o, v);
        w16(b, o + 2, v >> 16);
    }
}
