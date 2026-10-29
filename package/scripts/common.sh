#!/system/bin/sh
# aa.dpi - change the display density (DPI) Android Auto renders at.
#
# The head unit hardcodes it in HKMC_GPM.apk (GalConnectionSession.
# initGalReceiver -> VideoSink.nearestVideoConfiguration). files/aadpi.jar
# rewrites those literals in place in whatever GPM is installed (stock-layout,
# Leafia, egmp-aa-ev-feat...), as long as its classes.dex is stored in the APK.
# The package ships no Hyundai/Google files.
#
# Install snapshots the live APK+odex, swaps in the patched APK and re-runs
# dexopt. Uninstall restores the snapshot byte for byte, but only if the live
# APK is still the one this package wrote (if another package replaced GPM in
# between, it is left alone).

export PATH=/data/nemesis/bin:/sbin:/vendor/bin:/system/sbin:/system/bin:/system/xbin
export LD_LIBRARY_PATH=/vendor/lib:/system/lib
export ANDROID_ROOT=${ANDROID_ROOT:-/system}
if [ -z "$BOOTCLASSPATH" ]; then
    export BOOTCLASSPATH=/system/framework/core.jar:/system/framework/conscrypt.jar:/system/framework/okhttp.jar:/system/framework/core-junit.jar:/system/framework/bouncycastle.jar:/system/framework/ext.jar:/system/framework/framework.jar:/system/framework/framework2.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/mms-common.jar:/system/framework/android.policy.jar:/system/framework/services.jar:/system/framework/apache-xml.jar:/system/framework/webviewchromium.jar:/system/framework/automotive.jar
fi

PKG_DIR=/data/nemesis/apps/aa.dpi
# preinstall runs from the staging dir; pre.sh sets FILES=./files first.
FILES=${FILES:-$PKG_DIR/files}
PAYLOAD=/data/nemesis/build/aa.dpi
BACKUP_DIR=/data/nemesis/backup/aa.dpi
OURS_FILE=$BACKUP_DIR/ours.md5
LOG=/data/nemesis/aa.dpi.log
HOLD_FILE=/data/nemesis/aa.dpi.stopped
USB_CONF=aa-dpi.txt

APP_DIR=/system/app
GPM_APK=$APP_DIR/HKMC_GPM.apk
GPM_ODEX=$APP_DIR/HKMC_GPM.odex
GPM_PKG=com.google.android.projection.sink
USB_DIRS="/storage/usb0 /storage/usb1 /storage/usb2 /mnt/media_rw/usb0 /mnt/media_rw/usb1 /mnt/media_rw/usb2"

log() {
    echo "$1"
    mkdir -p /data/nemesis 2>/dev/null || true
    echo "$1" >> "$LOG" 2>/dev/null || true
}

toast() {
    am broadcast -a com.hkmc.intent.action.TOAST \
        -e com.hkmc.intent.extra.TOAST_MESSAGE "$1" \
        --ez com.hkmc.intent.extra.TOAST_POPUPSHOWING true >/dev/null 2>&1 || true
}

sys_rw() {
    /system/xbin/nemesis remount rw >/dev/null 2>&1
}

sys_ro() {
    /system/xbin/nemesis remount ro >/dev/null 2>&1 || true
}

file_md5() {
    local _line
    _line=$(md5 "$1" 2>/dev/null) || return 1
    set -- $_line
    [ -n "$1" ] || return 1
    echo "$1"
}

chown_system() {
    chown 0.0 "$1" 2>/dev/null || chown 0:0 "$1" 2>/dev/null || true
}

# aadpi <args...>: run the patcher on the head unit's Dalvik VM
aadpi() {
    local _data=$PAYLOAD/vm
    mkdir -p "$_data/dalvik-cache" || return 1
    ANDROID_DATA=$_data /system/bin/dalvikvm -Xmx64m -cp "$FILES/aadpi.jar" AaDpi "$@"
}

# read_conf <file>: set DPI / REAL_DPI / TAP_LIMIT from KEY=VALUE lines that are present
read_conf() {
    local _l
    [ -f "$1" ] || return 1
    # no tr on this unit: values end at the first character that isn't
    # a digit or letter (drops CR from files saved on Windows, and spaces)
    while IFS=' 	' read -r _l || [ -n "$_l" ]; do
        case "$_l" in
            DPI=*) _l=${_l#DPI=}; DPI=${_l%%[!0-9a-z]*} ;;
            REAL_DPI=*) _l=${_l#REAL_DPI=}; REAL_DPI=${_l%%[!0-9a-z]*} ;;
            TAP_LIMIT=*) _l=${_l#TAP_LIMIT=}; TAP_LIMIT=${_l%%[!0-9a-z]*} ;;
        esac
    done < "$1"
    return 0
}

# load_conf: package default, then aa-dpi.txt from an install drive
load_conf() {
    local _d
    DPI=
    REAL_DPI=
    TAP_LIMIT=
    read_conf "$FILES/dpi.conf"
    for _d in $USB_DIRS; do
        if read_conf "$_d/$USB_CONF"; then
            log "settings from $_d/$USB_CONF"
            break
        fi
    done
    case "$DPI" in
        ''|*[!0-9]*) log "FAIL: DPI '$DPI' is not a number"; return 1 ;;
    esac
    case "$REAL_DPI" in
        ''|keep) ;;
        *[!0-9]*) log "FAIL: REAL_DPI '$REAL_DPI' is not a number or keep"; return 1 ;;
    esac
    [ -n "$REAL_DPI" ] || REAL_DPI=$DPI
    case "$TAP_LIMIT" in
        ''|on) TAP_LIMIT=on ;;
        off) ;;
        *) log "FAIL: TAP_LIMIT '$TAP_LIMIT' is not on or off"; return 1 ;;
    esac
    return 0
}

# NEMESIS 1.15 force-updates an installed package from a USB drive left in at
# boot; rename our descriptor so the reboot after install doesn't loop.
retire_usb_descriptor() {
    local _d
    for _d in $USB_DIRS; do
        [ -f "$_d/NEMESIS.data" ] || continue
        grep -q '^type=install' "$_d/NEMESIS.data" 2>/dev/null || continue
        grep -q 'aa\.dpi\.zip' "$_d/NEMESIS.data" 2>/dev/null || continue
        if mv "$_d/NEMESIS.data" "$_d/NEMESIS.data.installed" 2>/dev/null; then
            log "renamed $_d/NEMESIS.data to NEMESIS.data.installed"
        else
            log "WARN: could not rename $_d/NEMESIS.data - remove the USB drive before the head unit restarts"
        fi
    done
    return 0
}

clean_payload() {
    case "$PAYLOAD" in
        */data/nemesis/build/aa.dpi) rm -rf "$PAYLOAD"; rmdir "${PAYLOAD%/*}" 2>/dev/null ;;
    esac
    return 0
}

# copy beside the target, then rename over it
put_file() {
    local _src="$1"
    local _dst="$2"
    local _tmp="${_dst}.dpitmp"
    rm -f "$_tmp" 2>/dev/null || true
    cp -f "$_src" "$_tmp" || { rm -f "$_tmp" 2>/dev/null; return 1; }
    if ! cmp "$_src" "$_tmp" >/dev/null 2>&1; then
        rm -f "$_tmp" 2>/dev/null || true
        return 1
    fi
    chmod 644 "$_tmp" 2>/dev/null || true
    chown_system "$_tmp"
    mv "$_tmp" "$_dst" || { rm -f "$_tmp" 2>/dev/null; return 1; }
    chmod 644 "$_dst" 2>/dev/null || true
    chown_system "$_dst"
    if [ -x /system/bin/restorecon ]; then
        restorecon "$_dst" 2>/dev/null || true
    fi
    cmp "$_src" "$_dst" >/dev/null 2>&1
}

android_up() { [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ]; }

apps_hold() {
    android_up || return 0
    touch "$HOLD_FILE" 2>/dev/null || return 0
    if pm disable "$GPM_PKG" >/dev/null 2>&1; then
        log "stopped $GPM_PKG for the file swap"
    else
        log "WARN: could not stop $GPM_PKG"
    fi
    return 0
}

apps_release() {
    [ -f "$HOLD_FILE" ] || return 0
    android_up || return 0
    if pm enable "$GPM_PKG" >/dev/null 2>&1; then
        log "started $GPM_PKG again"
        rm -f "$HOLD_FILE"
    else
        log "WARN: could not start $GPM_PKG again"
    fi
    return 0
}

write_odex() {
    [ -x /system/bin/dexopt ] || { log "dexopt binary missing"; return 1; }
    log "dexopt $GPM_APK"
    /system/bin/dexopt --preopt "$GPM_APK" "$GPM_ODEX" "m=y,u=n" || return 1
    [ -s "$GPM_ODEX" ] || return 1
    chmod 644 "$GPM_ODEX" 2>/dev/null || true
    chown_system "$GPM_ODEX"
    if [ -x /system/bin/restorecon ]; then
        restorecon "$GPM_ODEX" 2>/dev/null || true
    fi
    return 0
}

wipe_dalvik() {
    rm -f /data/dalvik-cache/*HKMC_GPM* 2>/dev/null || true
    rm -f /data/dalvik-cache/arm/*HKMC_GPM* 2>/dev/null || true
    rm -f /cache/dalvik-cache/*HKMC_GPM* 2>/dev/null || true
}

# The APK carries classes.dex, so PackageManager looks in the dalvik cache and
# re-optimises at boot if it is empty. Prefill it with the odex.
prefill_dalvik() {
    local _cache="/data/dalvik-cache/system@app@HKMC_GPM.apk@classes.dex"
    [ -s "$GPM_ODEX" ] || return 0
    [ -d /data/dalvik-cache ] || return 0
    rm -f "${_cache}.tmp" 2>/dev/null || true
    if ! cp -f "$GPM_ODEX" "${_cache}.tmp" 2>/dev/null || ! cmp "$GPM_ODEX" "${_cache}.tmp" >/dev/null 2>&1; then
        rm -f "${_cache}.tmp" 2>/dev/null || true
        log "dalvik cache not filled; boot will optimize"
        return 0
    fi
    chmod 644 "${_cache}.tmp" 2>/dev/null || true
    chown 1000:1000 "${_cache}.tmp" 2>/dev/null || chown 1000.1000 "${_cache}.tmp" 2>/dev/null || true
    mv "${_cache}.tmp" "$_cache" 2>/dev/null || { rm -f "${_cache}.tmp" 2>/dev/null; return 0; }
    if [ -x /system/bin/restorecon ]; then
        restorecon "$_cache" 2>/dev/null || true
    fi
    log "dalvik cache filled for HKMC_GPM.apk"
    return 0
}

# the live APK is the one this package last wrote, and its snapshot is intact
live_is_ours() {
    [ -s "$OURS_FILE" ] && [ -s "$BACKUP_DIR/HKMC_GPM.apk" ] &&
    [ "$(file_md5 "$GPM_APK")" = "$(cat "$OURS_FILE")" ]
}
