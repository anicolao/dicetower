# DiceTower

DiceTower will turn physical dice rolls into results that digital games can use. A native iOS app will watch a dice tray through an overhead iPhone camera and recognize dice with on-device machine learning.

**Status: connected recognition prototype.** The native iOS app runs the recommended local d6 model on the camera feed, overlays face predictions, and shows a settled count and total. Named towers can publish roll thumbnails and predictions to Firebase, and a separate timing-metrics stream, with a live [web observer](https://anicolao.github.io/dicetower/) for independent tower tabs. Photo collection and ZIP export remain available. See [the iPhone guide](apps/ios/README.md). Readings are experimental and need visual verification.

## Prototype

The first version will recognize the upper faces of **one to six pip-based d6 dice** in a 3D-printed tray lined with black felt. A printed holder will suspend the iPhone in a fixed, nearly perpendicular overhead position, with the tray edges visible. Initial supported dice will be opaque, light-colored dice with dark pips; other colors will be evaluated separately.

The player will arm a roll and roll into the tray. The app will infer how many dice are present. After motion stops, the app will propose individual values and their total, with boxes over the dice for inspection. The player can confirm, correct, or retry. A result will enter local history and become available to copy/share only after confirmation. Uncertain or incomplete observations will ask for intervention.

The prototype will run recognition entirely on the phone and work offline. Training will happen on a Mac. Digital game integrations, arbitrary camera placement, polyhedral dice, and automatic submission to games are later work.

## Documents

- [Android prototype and Nix build guide](apps/android/README.md): native CameraX/ONNX recognition, Firebase sharing, APK builds and validation.
- [docs/FIREBASE.md](docs/FIREBASE.md): named towers, event streams, security, local testing, and deployment.
- [VISION.md](VISION.md): product direction, principles, and boundaries.
- [MVP_DESIGN.md](MVP_DESIGN.md): prior-work findings, dataset audit, training experiments, native app architecture, and measurable acceptance gates.
- [CORPUS_ASSESSMENT.md](CORPUS_ASSESSMENT.md): inspection of the supplied November 2026 test archive, including usable pip-d6 examples and ground-truth limitations.

The proposed starting point is the local `../dicecam/MyObjectDetector.mlproj` Create ML detector and its labeled images. [egirard/DiceCAM](https://github.com/egirard/DiceCAM) supplies useful prior work and an annotation editor; its latest available labels need reconciliation with local exports. The design records what was actually found rather than assuming every historical image is training-ready.

## Development approach

The current app provides native camera preview, scene-stillness detection, automatic/manual photographs, session notes, review, and ZIP export. It also performs on-device face recognition without a preset dice count. Additional rig data improved the model, but touching dice remain difficult. Local training artifacts and the model binary remain outside Git; the app guide records the required model resource.

The capture app supports iOS 17 and later. Development uses a Mac with Xcode; camera behavior needs a physical iPhone. Recognition and the remaining game-facing roll workflow are specified in the design documents. Build and release commands are in [apps/ios/README.md](apps/ios/README.md).

## License and provenance

DiceTower's original source and documentation are licensed under **GNU GPL version 3 only** (`GPL-3.0-only`); see [LICENSE](LICENSE).

Historical datasets, third-party code, and pretrained weights are not included in this documentation PR. Before importing any, record their provenance, applicable permissions, licenses, and attribution. DiceTower's license does not change the license of upstream material.
