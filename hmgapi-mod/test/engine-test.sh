#!/bin/sh
# The built mod (build/hmgapi/mod/aa-dpi, from hmgapi-mod/build.sh) through HMG-API's
# own engine on a desktop JVM, on fake head units with HMG-API's real hook maps
# (every car it has a map for), next to the Wireless CarPlay + Android Auto mod:
# the mod.json is valid; it has no app, and HMG-API publishes it live with its four
# settings (its settings page); its two hook points (and the speed field) are mapped
# on every car and its hooks load; and HMG-API's car check accepts any car.
#   HMGAPI=<HMG-API checkout> sh hmgapi-mod/test/engine-test.sh
set -e
cd "$(dirname "$0")/../.."
REPO=$PWD
HMGAPI=${HMGAPI:-$REPO/../HMG-API}
HMGAPI=$(cd "$HMGAPI" && pwd)
MOD=$REPO/build/hmgapi/mod/aa-dpi
[ -f "$MOD/hooks.jar" ] || { echo "build the mod first: sh hmgapi-mod/build.sh"; exit 1; }
CP=$(mktemp -d); T=$(mktemp -d)
trap 'rm -rf "$CP" "$T"' EXIT
javac --release 8 -Xlint:-options -nowarn -d "$CP" "$HMGAPI"/core/runtime/java/hmgapi/engine/*.java
fail=0
has() { case "$3" in *"$2"*) echo "ok    $1" ;; *) echo "FAIL  $1: wanted [$2] in:"; echo "$3" | sed 's/^/        /'; fail=1 ;; esac; }
hasnt() { case "$3" in *"$2"*) echo "FAIL  $1: [$2] in:"; echo "$3" | sed 's/^/        /'; fail=1 ;; *) echo "ok    $1" ;; esac; }

unit() {   # unit <ro.build.product>: a fake head unit with the maps, the mod and the Wireless mod
    R=$T/$1; rm -rf "$R"
    mkdir -p "$R/system/lib" "$R/system/app" "$R/data/hmgapi/mods" "$R/data/hmgapi/settings/allow"
    printf 'ro.build.product=%s\nro.build.version.release=4.4.2\n' "$1" > "$R/system/build.prop"
    cp -r "$HMGAPI/maps" "$R/data/hmgapi/maps"
    python3 -c 'import glob,json,sys; [print(p["id"]) for f in sorted(glob.glob(sys.argv[1]+"/core/hookpoints/*.json")) for p in json.load(open(f))["points"]]' "$HMGAPI" > "$R/data/hmgapi/maps/points.txt"
    cp -r "$MOD" "$R/data/hmgapi/mods/aa-dpi"
    cp -r "$HMGAPI/mods/wireless-carplay-aa" "$R/data/hmgapi/mods/wireless-carplay-aa"
    # maps not yet checked on a car run only with "testing maps" on (the owner's switch)
    touch "$R/data/hmgapi/settings/allow/testing_maps"
    # each map is tied to its stock files' md5s: stand-ins here, and the copy's md5s for them
    python3 - "$R" <<'PY'
import glob, hashlib, json, os, sys
R = sys.argv[1]
for cj in glob.glob(R + "/data/hmgapi/maps/*/*/*/*/car.json"):
    car = json.load(open(cj))
    for key in ("files", "app_files"):
        files = car.get(key)
        if not isinstance(files, dict):
            continue
        for path in files:
            f = R + path
            os.makedirs(os.path.dirname(f), exist_ok=True)
            if not os.path.exists(f):
                open(f, "wb").write(("stand-in " + path).encode())
            files[path] = hashlib.md5(open(f, "rb").read()).hexdigest()
    json.dump(car, open(cj, "w"), indent=2)
PY
}
eng() { set +e; out=$(HMGAPI_ROOT=$R HMGAPI_HOST=1 HMGAPI_PRODUCT=$P java -cp "$CP" hmgapi.engine.Engine "$@" 2>&1); rc=$?; set -e; }

# one unit per car HMG-API has a map for
for cj in "$HMGAPI"/maps/*/*/*/*/car.json; do
    P=$(python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print(c["products"][0] + "0000.V015.000." + c["firmware"])' "$cj")
    unit $P
    eng plan
    errs=$(echo "$out" | grep -i "aa-dpi" | grep -i "error\|isn.t one\|must be\|needs \|matches none\|won't load" || true)
    plan=$out
    # its settings page: HMG-API's published state (what its app and the running apps read)
    eng publish-state
    st=$(python3 - "$R/data/hmgapi/public/state.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))["mods"].get("aa-dpi")
if m is None:
    print("not in the state")
else:
    s = m.get("settings") or {}
    keys = sorted(s) if isinstance(s, dict) else sorted(x.get("key") for x in s)
    print("live=%s settings=%s" % (m.get("live"), ",".join(keys)))
PY
)
    has "$P: HMG-API publishes it live, with its settings" "live=True settings=dpi,real_dpi,tap_limit,video_window" "$st"
    out=$plan
    hasnt "$P: no problems with the mod" "aa-dpi" "$errs"
    hasnt "$P: hooks load" "aa-dpi won't load" "$out"
    hasnt "$P: no app" "dev.aadpi.settings" "$out"
    hasnt "$P: no app in the mod" "AaDpi.apk" "$(ls -R "$MOD")"
    case "$P" in NEEV.USA.*260507) echo "$out" > "$T/plan.txt" ;; esac
done
echo "--- plan on an Ioniq 5 (US 260507):"; sed 's/^/    /' "$T/plan.txt" 2>/dev/null | grep -i "aa-dpi\|aadpi" || true

# the two points and the speed field, mapped on every car
for m in "$HMGAPI"/maps/*/*/*/*; do
    r=$(python3 - "$m" <<'PY'
import glob, json, sys
have = {}
for f in glob.glob(sys.argv[1] + "/*.json"):
    if not f.endswith("/car.json"):
        have.update(json.load(open(f)))
missing = json.load(open(sys.argv[1] + "/car.json")).get("missing", {})
want = ["gpm.video_sink.nearest", "gpm.sensor_source.init", "gpm.sensor_source.speed"]
gone = [p for p in want if p not in have or p in missing]
print("missing: " + " ".join(gone) if gone else "all mapped")
PY
)
    has "${m#$HMGAPI/maps/}: the points it uses are mapped" "all mapped" "$r"
done

# any car (no "system"): HMG-API's own check
has "an EV6: for this car" "ok: aa-dpi supports this unit" "$(HMGAPI_ROOT=$T/none HMGAPI_PRODUCT=CVEV.USA.0000.V015.012.260507 java -cp "$CP" hmgapi.engine.SystemCheck "$MOD" 2>&1 || true)"
has "a Niro: for this car" "ok: aa-dpi supports this unit" "$(HMGAPI_ROOT=$T/none HMGAPI_PRODUCT=DEEV.USA.0000.V015.012.260507 java -cp "$CP" hmgapi.engine.SystemCheck "$MOD" 2>&1 || true)"
exit $fail
