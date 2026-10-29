#!/system/bin/sh
. /data/nemesis/apps/aa.dpi/scripts/common.sh

log "preuninstall aa.dpi"
trap '[ $? = 0 ] || { sys_ro; apps_release; }' EXIT

if [ ! -d "$BACKUP_DIR" ]; then
    log "no snapshot - nothing to restore"
    exit 0
fi

# Restore only if the live APK is still ours. If another package (Leafia,
# egmp-aa-ev-feat) replaced GPM since, its file stays and our snapshot is stale.
if ! live_is_ours; then
    log "live HKMC_GPM.apk is not this package's - leaving it alone"
    rm -rf "$BACKUP_DIR"
    exit 0
fi

apps_hold
if ! sys_rw; then
    log "FAIL: remount /system rw"
    exit 1
fi
_rc=0
put_file "$BACKUP_DIR/HKMC_GPM.apk" "$GPM_APK" || _rc=1
if [ -s "$BACKUP_DIR/HKMC_GPM.odex" ]; then
    put_file "$BACKUP_DIR/HKMC_GPM.odex" "$GPM_ODEX" || _rc=1
else
    rm -f "$GPM_ODEX" 2>/dev/null || true
fi
wipe_dalvik
sys_ro
apps_release
sync
if [ "$_rc" = 0 ]; then
    log "restored HKMC_GPM apk+odex"
    rm -rf "$BACKUP_DIR"
else
    log "FAIL: restore incomplete - keeping $BACKUP_DIR"
fi
exit "$_rc"
