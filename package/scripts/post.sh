#!/system/bin/sh
. /data/nemesis/apps/aa.dpi/scripts/common.sh

log "postinstall aa.dpi"
trap '[ $? = 0 ] || { sys_ro; apps_release; }' EXIT

_want=$(cat "$PAYLOAD/HKMC_GPM.apk.md5" 2>/dev/null)
if [ -z "$_want" ] || [ "$(file_md5 "$PAYLOAD/HKMC_GPM.apk")" != "$_want" ]; then
    log "FAIL: payload missing or changed since preinstall"
    exit 1
fi

apps_hold

# Fresh install: snapshot exactly what is live now (replacing a stale snapshot
# left after another package swapped GPM under us).
if [ "$(cat "$PAYLOAD/source" 2>/dev/null)" != snapshot ]; then
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR" || { log "FAIL: mkdir $BACKUP_DIR"; exit 1; }
    cp -f "$GPM_APK" "$BACKUP_DIR/HKMC_GPM.apk" &&
        cmp "$GPM_APK" "$BACKUP_DIR/HKMC_GPM.apk" >/dev/null 2>&1 ||
        { log "FAIL: snapshot $GPM_APK"; exit 1; }
    if [ -s "$GPM_ODEX" ]; then
        cp -f "$GPM_ODEX" "$BACKUP_DIR/HKMC_GPM.odex" &&
            cmp "$GPM_ODEX" "$BACKUP_DIR/HKMC_GPM.odex" >/dev/null 2>&1 ||
            { log "FAIL: snapshot $GPM_ODEX"; exit 1; }
    fi
    log "backed up live HKMC_GPM ($(file_md5 "$GPM_APK"))"
fi

if ! sys_rw; then
    log "FAIL: remount /system rw"
    exit 1
fi
if ! put_file "$PAYLOAD/HKMC_GPM.apk" "$GPM_APK"; then
    log "FAIL: install $GPM_APK"
    exit 1
fi
echo "$_want" > "$OURS_FILE"
log "OK: $GPM_APK replaced"

rm -f "$GPM_ODEX" 2>/dev/null || true
if ! write_odex; then
    rm -f "$GPM_ODEX" 2>/dev/null || true
    log "dexopt failed for HKMC_GPM; boot will optimize"
fi
wipe_dalvik
prefill_dalvik

sys_ro
apps_release
clean_payload
sync

retire_usb_descriptor
toast "AA DPI installed. Restarting now: remove the USB drive while it restarts."
log "done - rebooting"
sleep 3
exec /system/bin/reboot
log "FAIL: reboot returned - reboot the head unit by hand"
exit 0
