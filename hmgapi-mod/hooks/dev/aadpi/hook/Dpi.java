package dev.aadpi.hook;

/**
 * The mod's arithmetic, apart from the hooks so the host test runs it
 * (hmgapi-mod/test/DpiTest.java).
 */
final class Dpi {
    private Dpi() {}

    /** what the settings accept; outside it the car's own values stay */
    static final int MIN = 60, MAX = 480;

    /** the DPI to give Android Auto, or 0: leave the car's */
    static int density(int setting) {
        return setting >= MIN && setting <= MAX ? setting : 0;
    }

    /**
     * real_density: "keep" leaves the car's (167/200 on the wide screens), anything
     * else is the same as the DPI (what aa-proxy-rs and the NEMESIS package do).
     */
    static int real(String mode, int dpi, int carReal) {
        return "keep".equals(mode) ? carReal : dpi;
    }

    /** the offered sensor list without one type (the same array if it isn't there) */
    static int[] without(int[] in, int type) {
        int n = 0;
        for (int s : in) if (s != type) n++;
        if (n == in.length) return in;
        int[] out = new int[n];
        int i = 0;
        for (int s : in) if (s != type) out[i++] = s;
        return out;
    }
}
