# DiceTower

DiceTower will turn physical dice rolls into results that digital games can use. A native iOS app will watch a dice tray through an overhead iPhone camera and recognize dice with on-device machine learning.

**Status: design proposal.** This repository currently contains documentation and a license only. There is no app, training pipeline, or validated model yet.

## Prototype

The first version will recognize the upper faces of **one to six pip-based d6 dice** in a 3D-printed tray lined with black felt. A printed holder will suspend the iPhone in a fixed, nearly perpendicular overhead position, with the tray edges visible. Initial supported dice will be opaque, light-colored dice with dark pips; other colors will be evaluated separately.

The player will select the expected number of dice, arm a roll, and roll into the tray. After motion stops, the app will propose individual values and their total, with boxes over the dice for inspection. The player can confirm, correct, or retry. A result will enter local history and become available to copy/share only after confirmation. Uncertain or incomplete observations will ask for intervention.

The prototype will run recognition entirely on the phone and work offline. Training will happen on a Mac. Digital game integrations, arbitrary camera placement, polyhedral dice, and automatic submission to games are later work.

## Documents

- [VISION.md](VISION.md): product direction, principles, and boundaries.
- [MVP_DESIGN.md](MVP_DESIGN.md): prior-work findings, dataset audit, training experiments, native app architecture, and measurable acceptance gates.
- [CORPUS_ASSESSMENT.md](CORPUS_ASSESSMENT.md): inspection of the supplied November 2026 test archive, including usable pip-d6 examples and ground-truth limitations.

The proposed starting point is the local `../dicecam/MyObjectDetector.mlproj` Create ML detector and its labeled images. [egirard/DiceCAM](https://github.com/egirard/DiceCAM) supplies useful prior work and an annotation editor; its latest available labels need reconciliation with local exports. The design records what was actually found rather than assuming every historical image is training-ready.

## Development approach

Review the design before implementation. The first implementation milestone will inventory and validate the existing data, evaluate the historical detector on fresh tray captures, and train a reproducible six-class Create ML baseline. Subsequent milestones will build the SwiftUI/AVFoundation/Vision/Core ML app and validate complete roll sessions on the mounted phone.

The proposed deployment floor is iOS 18, with an iPhone 13 as the initial performance reference, subject to checking the actual available phone before implementation. Development will require a Mac with Xcode and Create ML plus a physical iPhone for camera and performance testing. There are no build or run commands yet.

## License and provenance

DiceTower's original source and documentation are licensed under **GNU GPL version 3 only** (`GPL-3.0-only`); see [LICENSE](LICENSE).

Historical datasets, third-party code, and pretrained weights are not included in this documentation PR. Before importing any, record their provenance, applicable permissions, licenses, and attribution. DiceTower's license does not change the license of upstream material.
