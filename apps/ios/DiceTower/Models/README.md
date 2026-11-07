# Bundled recognition model

`DiceTowerD6.mlmodel` is the recommended local `rig-2026-11-06` model, SHA-256
`416678e1d7e4e7f7b867e1513fce072744a49c6feca3cdfb90b12417be8091b9`.
It is copied unchanged from `local-models/rig-2026-11-06/DiceTowerD6.mlmodel`.
The later `session-772337F9` candidate was not selected for this release.

Lineage: historical TinyYOLO detector at iteration 6,000, fine-tuned on the
first owner-approved rig corpus for 100 additional steps (last three convolution
layers). Native Core ML/Vision detector, six labels `1` through `6`, RGB416 square.
Joint confidence threshold 0.75; NMS IoU 0.30. Multiply Vision object confidence
by the selected label confidence. No expected dice count, top-k, or count prior.

The app EXIF-independent upright video frame is cropped to the adjustable tray
area, aspect-fit with Lanczos scaling to integer dimensions inside416×416,
then centered with black padding. Default crop is `(10,120)-(750,1080)` in
900×1200 reference coordinates, matching the broader second-session crop.
Existing user tray settings are preserved; use Reset tray area to use this default.
Vision boxes are mapped back through padding/crop to the full portrait preview.

The trained binary and corpus remain local artifacts, as in the training workflow.
To build from a fresh checkout, copy the above model into this directory before
regenerating the Xcode project. Xcode compiles it into the app; inference needs no
network. No captured images are included in the app or this repository.

Model limitations: selected with a small single-session validation set; touching
dice remain difficult. A stable reading is agreement across three model results
and image stillness, not a guarantee of correctness. Predictions remain separate
from approved corpus labels and are not automatically submitted to games.
