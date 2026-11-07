# DiceTower Android prototype

Version 0.1.5 normalizes finite confidence to [0,1], automatically recovers the known tiny confidence overflow in held rolls with original IDs, and shows queued/delivered/rejected status with dice values. Rejected or unsaved events cease to suppress future readings; offline pending events still prevent duplicates. Original repaired payloads are retained under Recovered. See [delivery recovery](../../docs/UPLOAD_RECOVERY.md).

Version 0.1.4 fixes upload queue blocking and adds held-upload recovery and diagnostics. See [the recovery policy](../../docs/UPLOAD_RECOVERY.md). Recognition/arming are unchanged.

Version 0.1.3 restores the original sensitive detection/arming sequence and filters
duplicate conclusions after recognition. The app and observer show a cumulative
session discard count; each discarded reading produces a metrics sample linking
to its original event. See [the exact strategy](../../docs/RECOGNITION.md).

Native Kotlin/Compose, CameraX and on-device ONNX Runtime CPU recognition. Android 10+ (API 29), ARM64 phones, rear camera, portrait orientation. Mount the phone above the black-felt tray with the tray visible; adjust the four crop margins so recognition covers the tray. The preview overlays predictions and displays count, total, inference time, processing time, inference EMA, interval and agreement count. Dice count is inferred automatically.

Name the tower and enable sharing to use the existing [web observer](https://anicolao.github.io/dicetower/), or choose **Keep local**. Recognition works offline. The screen must stay open for capture; backgrounding pauses the camera. Full-resolution corpus capture, photo review and ZIP export remain iOS-only for this first Android version. Readings are experimental and require visual verification. This is a sideloaded debug APK, not a Play Store release.

## Build with Nix

Install Nix with flakes enabled. All required developer tools come from the pinned `flake.lock`: JDK 17, Gradle 8.14.4, Android SDK/platform/build-tools 36, optional emulator/system image, Python 3.12, uv and Firebase CLI. No Android Studio or globally installed Java/Gradle is needed. Supported build hosts: Apple Silicon/Intel macOS and x86_64 Linux. The SDK packages require acceptance of their upstream licenses; the flake sets `android_sdk.accept_license` explicitly. Gradle Maven dependencies and Python dependencies are pinned in `app/gradle.lockfile` and `tools/android-model/uv.lock`. Initial use needs network access; these are pinned development commands, not sandboxed offline Nix derivations.

From the repository root, with the existing local model and prepared second-session corpus present:

```sh
nix run .#export-android-model -- --fixture-index 20
nix run .#android-build
nix run .#android-test
```

The exporter defaults to `local-models/rig-2026-11-06/DiceTowerD6.mlmodel` and `local-models/session-772337F9`. Override `--source`, `--corpus`, `--output` or `--report` as needed, preserving the selected checkpoint hash. It creates ignored `app/src/main/assets/DiceTowerD6.onnx` and `model-info.json`. The optional fixture copies approved held-out capture 20 and its human-approved values into ignored **test** assets; photos are never bundled in the main app. Model weights and private corpus files are not in Git. A fresh public checkout can run unit tests/lint immediately, but needs those local artifacts to build a usable recognition APK or run model/device tests. Missing model assets fail the normal build explicitly.

The default build produces `apps/android/app/build/outputs/apk/debug/app-debug.apk` for ARM64, signed with the local Android debug key. Install on a USB-debugging-enabled phone, specifying its serial:

```sh
nix develop -c adb devices
nix develop -c adb -s PHONE_SERIAL install -r apps/android/app/build/outputs/apk/debug/app-debug.apk
```

Allow camera permission when prompted. Updating an APK signed on a different workstation may require uninstalling first, which removes that installation's anonymous tower identity and pending uploads. Backups/device transfer are disabled to avoid cloning an identity or queue onto another phone. A production signing/release workflow is future work.

## Recognition and model parity

The exporter reconstructs the exact shipping Core ML network through `tools/ml/warmstart.py` and exports float32 ONNX opset 17; it does not retrain or quantize. Input is RGB NCHW float32 `[1,3,416,416]` divided by 255. Android applies the same integer crop/letterbox geometry, Lanczos3 resize and black padding, decodes joint objectness/class scores, thresholds at 0.75, and uses class-agnostic NMS at IoU 0.30. Boxes map back to the upright full preview/thumbnail. CPU execution uses up to four intra-op threads; there is no GPU/NNAPI dependency.

Source Core ML SHA-256: `416678e1d7e4e7f7b867e1513fce072744a49c6feca3cdfb90b12417be8091b9`.

Exported ONNX SHA-256: `284e178c7c4ad50526ad8ce535bd55c91b0e70ea76aa80cb00e95a12ba9e0c1d`.

Runtime verifies model lineage and ONNX checksum. Firebase events identify the actual ONNX artifact; its hash differs from the source Core ML file. See [MODEL_REPORT.json](MODEL_REPORT.json) for measured conversion parity and an emulator benchmark. Export checks PyTorch/ONNX raw outputs and, on macOS, native Core ML CPU retained detections over all 20 held-out images. It requires identical predicted face multisets, retained score error at most 0.003 and matched retained-box IoU at least 0.99. Low-confidence discarded proposals can differ more and are recorded separately. This establishes conversion parity on those images, not perfect ground-truth accuracy or equivalence on every future image. The existing model's difficult touching/obscured dice remain difficult. Full per-image results stay in `local-models/android/parity.json`.

Luma motion analysis runs at about 20 Hz. Stillness requires 200 ms and at least three samples; local and anchor differences catch small continuing motion. Inference uses the latest available frame with one in-flight request. Inference EMA uses alpha 0.2; target interval is rounded up to a minimum 50 ms, and overruns wait for the next 50 ms boundary. There is no extra fixed reporting delay. Two still-frame results must agree in values and box centers before one event is emitted. The engine then remains quiescent until movement, a camera-frame gap, crop change or lifecycle restart rearms it; a new roll with the same values still gets a new roll ID. Empty-tray agreement can report zero dice, matching the current iOS policy.

`inferenceMs` measures the ONNX call; `processingMs` includes preprocessing, inference and decoding, excluding thumbnail encoding, disk and upload. Model initialization is outside the inference timer. The UI and Firebase metrics stream show these values alongside EMA, interval, agreement, inference count and phase. Phone camera/exposure, processing and network time can add latency beyond the model call. Physical-device speed, thermal behavior and real-tray camera alignment still need validation.

## Firebase

Uses the existing `dicetower-anicolao` project and Android app registration `org.boardgamescafe.dicetower`. `firebase-config.json` contains public client configuration; access is enforced by existing database rules. Firebase Auth manages the anonymous account and token refresh. Owner UID is the tower ID; towers, rolls and metrics use the existing schemas described in [FIREBASE.md](../../docs/FIREBASE.md). No rules or observer migration is needed. Each phone installation owns its stream, and separate observer tabs can select different towers.

Sharing sends a small JPEG thumbnail, normalized boxes, values, timestamps and model hash for each accepted roll. Metrics are a separate stream. Atomic files under `noBackupFilesDir` queue uploads before networking. Rolls use conditional creates with stable event IDs, so a lost acknowledgement cannot duplicate a roll; metrics retry the same batches (up to 100 records). A changed anonymous identity preserves and refuses the old owner's queue. Pending uploads retry immediately and every 15 seconds in the foreground, with a tower heartbeat once a minute. Turning sharing off stops new enqueueing and preserves pending files; an already-started request may finish. Recognition continues locally. Uninstalling/clearing app data loses the anonymous identity and local queue.

## Verification

```sh
# Model-independent JVM tests and lint; also used in GitHub Actions.
nix run .#android-test

# Starts and cleans up its own API 36 emulator; local model/fixture required.
nix run .#android-device-test

# Explicit opt-in to a real QA tower in the existing Firebase project.
DICETOWER_LIVE_FIREBASE_QA=1 nix run .#android-device-test
```

The emulator helper refuses an occupied port (default 5580; override `DICETOWER_ANDROID_PORT`). Hardware virtualization must be available. It chooses the host ABI, compiles both APKs, runs instrumentation, saves screenshot/logcat/benchmark under `local-models/android/device`, and stops only its own emulator. Live Firebase is skipped by default. With live QA enabled, it saves the new QA tower ID; inspect and delete **only that QA UID** under `/towers`, `/rolls` and `/metrics` afterward using the administrator Firebase CLI. The anonymous auth account can remain unused.

Tests cover timing/agreement/rearm, geometry/rotation/NMS/pixel normalization, persisted queue retries/lost acknowledgements and owner changes. Device tests exercise real ONNX inference, quiescence/rearm, camera preview/UI and optional real Firebase auth, roll idempotency and metric retries. Emulator timings do not predict physical-phone performance. CI omits private weights/fixtures and uses the explicit `skipModelCheck` flag for compile/unit/lint checks only; do not distribute that model-free build. Supply `-PtargetAbi=x86_64` for an Intel emulator build; normal phone APKs remain ARM64.

## Dependencies and license

Original Android source is GPL-3.0-only under the repository license. Upstream AndroidX, Kotlin, Firebase and ONNX Runtime retain their own licenses; model/data provenance is the same as the existing iOS checkpoint, and no third-party training data or weights are added to Git. Development references: [CameraX image analysis](https://developer.android.com/media/camera/camerax/analyze), [ONNX Runtime Java/Android](https://onnxruntime.ai/docs/get-started/with-java.html), [Firebase anonymous authentication](https://firebase.google.com/docs/auth/android/anonymous-auth).
