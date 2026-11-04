#!/bin/sh
# Host tests for the aa-dpi HMG-API mod (no car):
#  - DpiTest: the DPI range, real density and the sensor list without speed
#  - engine-test.sh: the built mod through HMG-API's own engine (needs
#    sh hmgapi-mod/build.sh first)
#   HMGAPI=<HMG-API checkout> sh hmgapi-mod/test/run.sh
set -e
cd "$(dirname "$0")/../.."
REPO=$PWD
HMGAPI=${HMGAPI:-$REPO/../HMG-API}
HMGAPI=$(cd "$HMGAPI" && pwd)
OUT=build/hmgapi/test
rm -rf "$OUT" && mkdir -p "$OUT"
javac -nowarn -d "$OUT" hmgapi-mod/hooks/dev/aadpi/hook/Dpi.java hmgapi-mod/test/DpiTest.java
java -cp "$OUT" dev.aadpi.hook.DpiTest
HMGAPI="$HMGAPI" sh hmgapi-mod/test/engine-test.sh
