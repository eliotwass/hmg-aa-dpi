#!/system/bin/sh
# aa.dpi status, for the NEMESIS manager.
. /data/nemesis/apps/aa.dpi/scripts/common.sh
PAYLOAD=/data/nemesis/build/aa.dpi.status

echo "== aa.dpi =="
echo "live HKMC_GPM.apk:  $(file_md5 $GPM_APK)"
echo "written by aa.dpi:  $(cat $OURS_FILE 2>/dev/null)"
if live_is_ours; then
    echo "state: installed"
else
    echo "state: NOT active (GPM was replaced by another package; reinstall aa.dpi)"
fi
echo "-- densities the live GPM advertises --"
aadpi scan "$GPM_APK" 2>&1
rm -rf "$PAYLOAD"
echo "-- recent log --"
# last 15 lines without tail (the unit has none): a ring of 15 variables
if [ -f "$LOG" ]; then
    _n=0
    while IFS= read -r _l; do
        eval "_r$((_n % 15))=\$_l"
        _n=$((_n + 1))
    done < "$LOG"
    _i=$((_n > 15 ? _n - 15 : 0))
    while [ "$_i" -lt "$_n" ]; do
        eval "echo \"\$_r$((_i % 15))\""
        _i=$((_i + 1))
    done
else
    echo "(no log)"
fi
