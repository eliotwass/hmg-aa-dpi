package dev.aadpi.hook;

import hmgapi.hook.LoadedApp;
import hmgapi.hook.MethodHook;
import hmgapi.hook.ModContext;
import hmgapi.hook.ModEntry;
import hmgapi.hook.Points;

/**
 * Android Auto's DPI and its tap/scroll limit, in the Android Auto app (GPM)
 * while it runs: what the NEMESIS package does by rewriting GPM's dex, with two
 * HMG-API hook points and nothing changed on disk.
 *
 * - gpm.video_sink.nearest (VideoSink.nearestVideoConfiguration(width, height,
 *   density, realDensity, fps, depth)): every video setting the car offers the
 *   phone gets the DPI as density, and as real density unless "keep".
 * - gpm.sensor_source.init (type, native, sensors, location, fuel types, EV
 *   connectors): with the tap limit off, the speed sensor isn't offered, so the
 *   phone doesn't apply its tap/scroll lockout while moving (aa-proxy-rs's
 *   remove_tap_restriction). Driving status still goes to the phone.
 *
 * Both read the settings when they run, and HMG-API hands every running app a
 * saved change at once (from HMG-API's settings page for the mod), so
 * a change applies at the next Android Auto connection: the phone asks for
 * these only when it connects.
 */
public final class DpiHooks extends ModEntry {
    static final String GPM = "com.google.android.projection.sink";

    @Override
    public void appLoaded(final ModContext mod, LoadedApp app) {
        if (!GPM.equals(app.packageName) || !GPM.equals(app.processName)) return;
        if (!Points.has("gpm.video_sink.nearest") || !Points.has("gpm.sensor_source.init") || !Points.has("gpm.sensor_source.speed")) {
            mod.error("the Android Auto app isn't mapped on this car: DPI and tap limit stay stock", null);
            return;
        }
        final ClassLoader cl = app.classLoader;
        final int speed = ((Integer) Points.get(cl, "gpm.sensor_source.speed", null)).intValue();

        mod.hook(cl, "gpm.video_sink.nearest", new MethodHook() {
            @Override
            protected void beforeHookedMethod(Param p) {
                int d = Dpi.density(mod.settingInt("dpi", 0));
                if (d == 0 || !(p.args[2] instanceof Integer) || !(p.args[3] instanceof Integer)) return;
                p.args[3] = Dpi.real(mod.settingString("real_dpi", "same"), d, (Integer) p.args[3]);
                p.args[2] = d;
            }
        });

        mod.hook(cl, "gpm.sensor_source.init", new MethodHook() {
            @Override
            protected void beforeHookedMethod(Param p) {
                boolean limit = mod.settingBoolean("tap_limit", true);
                if (!limit && p.args[2] instanceof int[]) p.args[2] = Dpi.without((int[]) p.args[2], speed);
                int d = Dpi.density(mod.settingInt("dpi", 0));
                mod.log("Android Auto connecting: DPI " + (d == 0 ? "stock" : d + " (real density " + mod.settingString("real_dpi", "same") + ")")
                        + ", tap/scroll limit " + (limit ? "on (stock)" : "off"));
            }
        });
        mod.log("DPI and tap limit hooks in " + app.processName);
    }
}
