#!/system/bin/sh
# NEMESIS runs preinstall from the staging dir, before the tree is copied to
# /data/nemesis/apps/aa.dpi: source relatively and use the staged files.
FILES=./files
. ./scripts/common.sh

log "preinstall aa.dpi"
trap '[ $? = 0 ] || clean_payload' EXIT
if [ ! -x /system/xbin/nemesis ]; then
    log "FAIL: /system/xbin/nemesis missing"
    exit 1
fi
for _f in aadpi.jar dpi.conf; do
    if [ ! -s "$FILES/$_f" ]; then
        log "FAIL: $FILES/$_f missing"
        exit 1
    fi
done
if [ ! -x /system/bin/dalvikvm ]; then
    log "FAIL: /system/bin/dalvikvm missing"
    exit 1
fi

if ! load_conf; then
    toast "AA DPI not installed: bad DPI or TAP_LIMIT setting. Nothing was changed."
    exit 1
fi
log "DPI=$DPI REAL_DPI=$REAL_DPI TAP_LIMIT=$TAP_LIMIT"
_notap=
[ "$TAP_LIMIT" = off ] && _notap=notap

# Reinstall (or a DPI change) over our own APK: patch the snapshot, not the
# already-patched file. Otherwise patch whatever GPM is live now.
clean_payload
mkdir -p "$PAYLOAD" || { log "FAIL: mkdir $PAYLOAD"; exit 1; }
log "live: apk=$(file_md5 "$GPM_APK") odex=$(file_md5 "$GPM_ODEX")"
if live_is_ours; then
    log "live HKMC_GPM.apk is this package's - patching the snapshot again"
    _src=$BACKUP_DIR/HKMC_GPM.apk
    echo snapshot > "$PAYLOAD/source"
else
    _src=$GPM_APK
    echo live > "$PAYLOAD/source"
fi

if ! aadpi patch "$_src" "$PAYLOAD/HKMC_GPM.apk" "$DPI" "$REAL_DPI" $_notap >> "$LOG" 2>&1; then
    log "FAIL: could not patch $_src (see log above)"
    toast "AA DPI not installed: this head unit's Android Auto app is not supported. Nothing was changed."
    exit 1
fi
if ! aadpi scan "$PAYLOAD/HKMC_GPM.apk" >> "$LOG" 2>&1; then
    log "FAIL: patched APK did not verify"
    toast "AA DPI not installed: the patched file did not verify. Nothing was changed."
    exit 1
fi
file_md5 "$PAYLOAD/HKMC_GPM.apk" > "$PAYLOAD/HKMC_GPM.apk.md5" || exit 1

log "preinstall ok"
exit 0
