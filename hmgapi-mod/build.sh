#!/bin/sh
# Build the aa-dpi HMG-API mod into build/hmgapi/mod/aa-dpi/ (and, with an author
# key, the signed package dist/aa-dpi-<version>.zip).
#
#   sh hmgapi-mod/build.sh                 the mod folder (unsigned)
#   sh hmgapi-mod/build.sh <author key>    plus the signed package, through
#                                          HMG-API's tools/mkmodpkg.sh
#
# Needs an HMG-API checkout (HMGAPI, default ../HMG-API next to this repo; its
# runtime is built here: a JDK and the Android SDK, no clang), a JDK
# and the Android SDK (build-tools, a platform android.jar; ANDROID_HOME).
# A new author key: java -cp "$HMGAPI/out/engine-host" hmgapi.engine.Signing keygen <file>
#
# No app: the settings are on HMG-API's settings page for the mod (settings.json).
set -e
cd "$(dirname "$0")/.."
REPO=$PWD
HMGAPI=${HMGAPI:-$REPO/../HMG-API}
[ -f "$HMGAPI/tools/env.sh" ] || { echo "no HMG-API checkout at $HMGAPI (set HMGAPI)" >&2; exit 1; }
HMGAPI=$(cd "$HMGAPI" && pwd)
. "$HMGAPI/tools/env.sh"
[ -x "$D8" ] && [ -f "$ANDROID_JAR" ] || { echo "Android SDK not found (ANDROID_HOME)" >&2; exit 1; }

ID=aa-dpi
VER=$(sed -n 's/.*"version": *"\([^"]*\)".*/\1/p' hmgapi-mod/mod.json | head -1)
B=build/hmgapi
MOD=$B/mod/$ID
rm -rf "$B/hooks" "$MOD"
mkdir -p "$B/hooks" "$MOD"

echo "== HMG-API runtime ($HMGAPI)"
(cd "$HMGAPI" && sh build.sh runtime >/dev/null)

echo "== hooks.jar"
javac --release 8 -Xlint:-options -nowarn -cp "$ANDROID_JAR:$HMGAPI/out/classes" -d "$B/hooks" $(find hmgapi-mod/hooks -name '*.java')
"$D8" --release --min-api 19 --lib "$ANDROID_JAR" --classpath "$HMGAPI/out/classes" --output "$MOD/hooks.jar" $(find "$B/hooks" -name '*.class')

echo "== mod folder"
cp hmgapi-mod/mod.json hmgapi-mod/settings.json "$MOD/"
(cd "$MOD" && find . -type f | sort | xargs md5 -r 2>/dev/null || find . -type f | sort | xargs md5sum)

if [ -n "$1" ]; then
    echo "== signed package"
    # HMG-API's packer signs with <key> and the <key>.pub beside it, then verifies
    sh "$HMGAPI/tools/mkmodpkg.sh" "$REPO/$MOD" "$1" > "$B/mkmodpkg.log" 2>&1 || { cat "$B/mkmodpkg.log" >&2; exit 1; }
    Z=$(tail -1 "$B/mkmodpkg.log")
    [ -f "$Z" ] || { cat "$B/mkmodpkg.log" >&2; echo "no signed package made" >&2; exit 1; }
    mkdir -p dist
    cp "$Z" "dist/$ID-$VER.zip"
    echo "dist/$ID-$VER.zip"
fi
