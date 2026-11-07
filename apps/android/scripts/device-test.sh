#!/usr/bin/env bash
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
: "${ANDROID_HOME:?Run through nix develop .#android-emulator}"
export ANDROID_AVD_HOME="$PWD/local-models/android/avd"
artifact_dir="$PWD/local-models/android/device"
mkdir -p "$ANDROID_AVD_HOME" "$artifact_dir"
test -f apps/android/app/src/androidTest/assets/golden.png || { echo 'Prepare the local fixture: nix run .#export-android-model -- --fixture-index 20' >&2; exit 1; }
port="${DICETOWER_ANDROID_PORT:-5580}"
serial="emulator-$port"
if adb devices | grep -q "^$serial[[:space:]]"; then
  echo "Port $port already belongs to a device. Choose another DICETOWER_ANDROID_PORT." >&2
  exit 1
fi
abi="${DICETOWER_ANDROID_ABI:-arm64-v8a}"
if ! printf 'no\n' | avdmanager create avd --force --name DiceTowerQA --package "system-images;android-36;google_apis;$abi" --device pixel_7 > "$artifact_dir/avd.log" 2>&1; then
  # Some SDK images lack devices.xml, but avdmanager still produces the full AVD.
  test -f "$ANDROID_AVD_HOME/DiceTowerQA.avd/config.ini" || { cat "$artifact_dir/avd.log" >&2; exit 1; }
fi
emulator -avd DiceTowerQA -port "$port" -no-window -no-audio -no-snapshot -no-boot-anim -gpu swiftshader -camera-back virtualscene -camera-front none > "$artifact_dir/emulator.log" 2>&1 &
emulator_pid=$!
cleanup() {
  adb -s "$serial" logcat -d > "$artifact_dir/logcat.txt" 2>/dev/null || true
  adb -s "$serial" emu kill >/dev/null 2>&1 || true
  wait "$emulator_pid" 2>/dev/null || true
}
trap cleanup EXIT
for attempt in $(seq 1 120); do
  if [[ "$(adb -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; then break; fi
  if ! kill -0 "$emulator_pid" 2>/dev/null; then cat "$artifact_dir/emulator.log" >&2; exit 1; fi
  sleep 2
done
[[ "$(adb -s "$serial" shell getprop sys.boot_completed | tr -d '\r')" == 1 ]]
gradle --no-daemon --console=plain -p apps/android assembleDebug assembleDebugAndroidTest -PtargetAbi="$abi"
adb -s "$serial" install -r -t apps/android/app/build/outputs/apk/debug/app-debug.apk
adb -s "$serial" install -r -t apps/android/app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
live=false
if [[ "${DICETOWER_LIVE_FIREBASE_QA:-0}" == 1 ]]; then live=true; fi
adb -s "$serial" shell am instrument -w -e liveFirebase "$live" org.boardgamescafe.dicetower.test/androidx.test.runner.AndroidJUnitRunner | tee "$artifact_dir/instrumentation.txt"
grep -Eq 'OK \([0-9]+ tests?\)' "$artifact_dir/instrumentation.txt"
! grep -q 'FAILURES!!!' "$artifact_dir/instrumentation.txt"
for file in android-benchmark.json android-ui.png android-ui-tree.txt; do
  adb -s "$serial" exec-out run-as org.boardgamescafe.dicetower cat "no_backup/$file" > "$artifact_dir/$file"
done
if [[ "$live" == true ]]; then
  adb -s "$serial" exec-out run-as org.boardgamescafe.dicetower cat no_backup/qa-tower-id.txt > "$artifact_dir/qa-tower-id.txt"
  echo "Live QA tower ID saved in $artifact_dir/qa-tower-id.txt. Remove only this QA tower/roll/metrics data with the administrator CLI after inspection."
fi
