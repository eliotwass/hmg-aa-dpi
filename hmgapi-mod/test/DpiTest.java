package dev.aadpi.hook;

/** Host test of the mod's arithmetic (hmgapi-mod/test/run.sh). */
public final class DpiTest {
    static int passed, failed;

    static void check(String what, boolean ok) {
        if (ok) passed++;
        else { failed++; System.out.println("FAIL  " + what); }
    }

    public static void main(String[] a) {
        check("200 is used", Dpi.density(200) == 200);
        check("60 and 480 are the limits", Dpi.density(60) == 60 && Dpi.density(480) == 480);
        check("59 leaves the car's", Dpi.density(59) == 0);
        check("481 leaves the car's", Dpi.density(481) == 0);
        check("0 (unset) leaves the car's", Dpi.density(0) == 0);
        check("real density: same as the DPI", Dpi.real("same", 180, 167) == 180);
        check("real density: anything but keep is the same", Dpi.real("", 180, 167) == 180);
        check("real density: keep the car's", Dpi.real("keep", 180, 167) == 167);
        int[] sensors = {1, 10, 13, 2, 7};
        int[] out = Dpi.without(sensors, 10);
        check("speed left out", out.length == 4 && out[0] == 1 && out[1] == 13 && out[2] == 2 && out[3] == 7);
        check("a list without it is the same list", Dpi.without(out, 10) == out);
        check("the car's list isn't changed", sensors[1] == 10 && sensors.length == 5);
        check("every one of a repeated type", Dpi.without(new int[] {10, 3, 10}, 10).length == 1);
        check("video window: 8 is set", Dpi.window(8) == 8);
        check("video window: the default (6) is set", Dpi.WINDOW_DEFAULT == 6 && Dpi.window(Dpi.WINDOW_DEFAULT) == 6);
        check("video window: 1 and 16 are the limits", Dpi.window(1) == 1 && Dpi.window(16) == 16);
        check("video window: the car's 4 is left alone", Dpi.window(4) == 0);
        check("video window: 0 or 17 leaves the car's", Dpi.window(0) == 0 && Dpi.window(17) == 0);
        System.out.println("DpiTest: " + passed + " passed, " + failed + " failed");
        if (failed > 0) System.exit(1);
    }
}
