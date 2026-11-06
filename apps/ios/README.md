# DiceTower Capture for iPhone

The first native app collects training photographs on the real rig. It detects stillness on the phone, saves one original JPEG per settled scene, and exports session ZIPs for later human labeling. It does not run the experimental dice-recognition model or request an advance dice count.

## Capture a session

1. Install **DiceTower Capture** through TestFlight and allow camera access. Mount the phone above the tray with all edges visible. The app uses the rear wide camera at 1×, flash off, and a fixed portrait coordinate system.
2. Open Capture settings. Match the dashed tray frame to the tray interior; movement outside it is ignored. The complete photo is retained. Let focus/exposure adjust, then optionally lock focus, exposure, and white balance.
3. Use **+** to create a session with notes describing the dice set, mount height, felt, and lighting. Start a new session when those conditions change so we can split future datasets by session.
4. Tap **Start auto capture**. After 1.2 seconds of stillness, the first photo saves. An empty-tray first photo is useful background data. Roll or rearrange dice, remove your hands, and wait for the saved counter to increase before repeating. An unchanged scene is not repeatedly captured.
5. Use the camera button for a manual shot, including unusual scenes you want to document. Auto capture pauses when the app leaves the foreground; restart it after returning. Pause before moving the holder or changing settings.
6. Use Share to export a session ZIP through AirDrop or Save to Files. Previous sessions and full-size photos are available from the library button. The app also exposes its Documents folder through Files/Finder file sharing. Export collected data before uninstalling the app.

If tiny movements are missed, choose High motion sensitivity. If noise prevents settling, choose Low or improve the lighting. Increase the settling time for slow dice. This capture build measures scene motion; a stationary hand can also produce a photo. Review and label scenes later rather than assuming every saved image is a valid roll.

## Corpus format

```text
Documents/DiceTower/Sessions/<session UUID>/
  session.json
  captures/<capture UUID>/
    image.jpg
    thumbnail.jpg
    capture.json
```

`session.json` records schema version, session ID/date, rig notes, phone hardware model, OS, and app version/build. `capture.json` records the trigger (automatic/manual), timestamp, required settling time, motion threshold/score, normalized tray insets, camera settings, image dimensions/orientation, media timestamps, and the original JPEG's SHA-256. All captures start as **unlabeled**. No `expected.json` or predicted face values are manufactured.

The JPEG is the camera's original output, including EXIF orientation; readers must honor that orientation. Tray insets use upright portrait coordinates and refer to motion analysis, not preexisting die boxes. Thumbnails are orientation-correct display derivatives, not training originals. Automatic captures require a shutter timestamp within 0.6 seconds of the triggering frame and reject observed movement before the shutter. Movement after the exposure does not invalidate a saved photograph.

Each image/metadata pair is written outside the session and published by a directory rename only after both writes succeed. Failed writes remain in `Documents/DiceTower/PendingCaptures` for recovery and are excluded from session ZIPs. Successful photos persist across app restarts and updates. An export uses Foundation's coordinated directory ZIP snapshot; it is copied before the temporary snapshot disappears. There is no account, analytics, server, or automatic network upload in the app.

## Build and verify

Environment: Xcode 26.6, iOS 26.5 simulator, XcodeGen 2.46.0; iPhone deployment target iOS 17. No third-party runtime dependencies. The generated Xcode project is committed; `generate-project.sh` downloads and verifies the pinned generator when needed.

From the repository root:

```sh
apps/ios/scripts/generate-project.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path apps/ios/Core
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test \
  -project apps/ios/DiceTower.xcodeproj -scheme DiceTower \
  -destination 'platform=iOS Simulator,name=DiceTower Capture QA,OS=26.5' \
  -derivedDataPath apps/ios/DerivedData -parallel-testing-enabled NO
```

The motion tests use explicit frame timestamps, not sleeps. They cover one capture per scene, rearming after movement, continuous motion, camera gaps, slow drift, sensor noise, small moving regions, and failed-save retry. Storage tests verify original bytes/hash, recovery across a new store instance, duplicate-ID protection, and readable ZIP contents. The native UI walkthrough tests actual persistence and ZIP sharing with a generated simulator fixture. That fixture exists only in Debug simulator builds under `-capture-demo`; it cannot run in a Release or physical-device build. Physical camera timing and threshold tuning still need confirmation on the printed rig.

The detector samples an upright 96×128 luminance grid inside the tray at approximately 10 Hz. It combines whole-region differences with local 12×12 tiles so one small moving die is visible, and compares against a settling anchor to reject slow drift. After a saved photo it requires new scene movement/change, with a short camera-recovery grace period, before another automatic capture.

## TestFlight release

The release scripts reuse the external Apple handoff used by MediNag. Credentials and signing identifiers are not committed. Override its location with `DICETOWER_APPLE_CONFIG`; the default is `~/.config/hunger/testflight.env`.

The bundle identifier is `org.boardgamescafe.dicetower`. First-time app registration requires one App Store Connect record: **DiceTower Capture**, iOS, SKU `dicetower-ios`, English (Canada). The bundle can be registered through:

```sh
node apps/ios/scripts/app-store-connect.mjs register
```

After the record exists:

```sh
node apps/ios/scripts/release-testflight.mjs
node apps/ios/scripts/app-store-connect.mjs status
```

The release command selects the next build number, archives/signs, verifies app identity, uploads, waits for processing, assigns the build to Internal, confirms the configured existing internal tester, and adds testing notes. `--archive-only` prepares a signed archive without an app record. Use `DICETOWER_BUILD_NUMBER=1` (or the appropriate number) to resume a prepared release. Logs, signing artifacts, and the server-confirmed release report remain in the ignored `apps/ios/DerivedData/TestFlight/<build>/` directory.
