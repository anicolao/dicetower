# MVP design proposal

Status: proposed for PR1 review; documentation only. Evidence inspected on 2026-11-06. All thresholds, budgets, and acceptance figures below are initial engineering targets, not measured DiceTower performance.

## 1. Decision and scope

Build a SwiftUI iOS app using AVFoundation for camera capture, Vision/Core ML for a **single six-class object detector**, and a deterministic roll state machine. Train on a Mac with Create ML, initially reusing audited historical images. Detect each die's upper face and classify its value directly as `1` through `6`. Do not start with a separate pip counter or a detector/classifier cascade.

The supported envelope is one to six opaque, light-colored d6 dice with dark pips, lying flat with fully visible tops on black felt. The player supplies the expected count. Diffuse lighting and a rigid overhead mount are part of the prototype. Test touching dice, tray-edge positions, and repeated values explicitly. Other dice and obstructed scenes should lead to intervention; a six-class detector alone cannot guarantee rejection of every unknown object.

Propose iOS 18 and an iPhone 13 as the first reference device. Confirm the owner's actual device before implementation, then record its hardware, iOS version, camera, tray dimensions, and mount height in every performance report. No simulator measurement substitutes for phone results. Install through Xcode for the prototype; App Store distribution is outside this milestone.

## 2. What the prior work actually provides

These are inspection findings, not a claim that all sources are independent or ready for redistribution.

| Source | Verified evidence | Intended use / limitation |
| --- | --- | --- |
| `../dicecam/MyObjectDetector.mlproj` | Create ML object detector; metadata says `darknetYolo`, 13×13 grid, snapshots at 8,000 and 8,020 iterations; exported model is about 32 MB | Preserve as a baseline to evaluate. Do not assume these internals describe the current Create ML default. |
| Its `Data Sources/processed.json` and `../dicecam/annotations/src/images/annotated/data/processed/` | 138 PNGs and 138 annotation records; 582 boxes across six classes. Counts: 1:75, 2:104, 3:101, 4:100, 5:112, 6:90 | Concrete starting corpus. The export uses legacy `imagefilename` / `annotation` keys; normalize for the selected toolchain. |
| Model-container and snapshot metadata | Automatic validation; stored `validationAccuracy` ≈0.9987; no separate test evaluation initialized | Historical tool output only. Its metric meaning and split independence have not been established; it is not 99.87% complete-roll accuracy. |
| Local `gene/data/` | 11 foreground/background/result triplets; image files contain data URLs; result arrays contain 37 entries, including two `0` labels | Candidate additional/corrected examples. Determine what `0` means; do not convert it into a valid die value. |
| Local `annotations/src/images/annotated/` tree | Multiple raw, decoded, and processed copies; 150 result arrays containing six `0` labels as well as 1–6 labels | Audit lineage and duplicates. File counts are not counts of independent labeled scenes. |
| [egirard/DiceCAM](https://github.com/egirard/DiceCAM/tree/4285a3575d97009ddd5107e760dd3dd8c9376dfb) | Upstream main inspected at `4285a3575d97009ddd5107e760dd3dd8c9376dfb`; annotation editor, sample photographs, and Apache-2.0 repository license. No committed label corpus found in that tree | Reconcile Gene's latest exported annotations with the local data before choosing authoritative labels. Repository access is required for these links. |
| DiceCAM's [notes](https://github.com/egirard/DiceCAM/blob/4285a3575d97009ddd5107e760dd3dd8c9376dfb/readme.md) and [annotation editor](https://github.com/egirard/DiceCAM/blob/4285a3575d97009ddd5107e760dd3dd8c9376dfb/annotations/src/routes/%2Bpage.svelte) | Prior work on tray masking, pip geometry, diagnostic overlays, and dice events; documented problems with bunched dice, glare, and dark dice | Retain the lessons and annotation workflow, not the browser/ESP32 architecture. |
| `/Volumes/Macintosh HD/Users/anicolao/projects/games/dicecam` | At inspection, the project subdirectories are empty; only three top-level files are present | No additional labeled or test images available there. Revisit if a fuller backup becomes available. |
| `../dicecam/cml/` and `dice_detection/` | Other historical data/training attempts; `cml/README.dataset.txt` identifies a Roboflow D&D dataset and CC BY 4.0 attribution | Secondary candidates only after relevance, face-label, duplication, and license checks. Do not mix polyhedral labels into the d6 task. |

The current upstream tree is newer than the local DiceCAM checkout (`376ca4a2294a68c7f8c9db12acc3a94ed1fac0b7`). Newer code does not establish newer training labels. A representative processed image is 320×180, oblique, and contains small dice on dark felt: useful starting material, but not the new overhead camera distribution. No inference benchmark was run for this documentation PR.

## 3. Physical setup and calibration

Print a tray with an unambiguous rectangular inner boundary and a rigid holder placing the rear main camera above its center. Keep all four edges in frame, with margin outside them. Use diffuse side lighting, avoid a phone shadow over the center, and provide power without obstructing the camera. Prefer a consistent lens and disable automatic lens switching where the chosen capture device permits it.

Start with 1920×1080 capture at 30 fps. Choose mount height after checking the smallest intended die in the detector input: target at least 32 pixels across its upper face after cropping/resizing. The historical images include smaller faces, so this is a design target to validate rather than an exclusion rule for old data. If the geometry cannot meet it, reduce tray area or increase model resolution before collecting a large dataset. Record actual dimensions rather than inventing tray measurements now.

On setup, show the full preview and ask the user to mark the four inner tray corners. Automatic rectangle detection may suggest corners but must allow adjustment. Capture an empty-tray reference, set the usable interior polygon with a small wall margin, and settle focus/exposure/white balance before locking supported controls. Freeze orientation for a session. Stop recognition and request recalibration when framing changes, the capture session restarts, or exposure quality becomes unsuitable.

For the first version, crop the axis-aligned bounding rectangle of the interior, mask outside its polygon, and aspect-fit it into the model's input with recorded padding. Do not add perspective warping unless the supposedly overhead rig requires it. Use identical transforms in training preparation and the app. Keep original frames and transform metadata for diagnostics. Tray walls are not valid rolling area; a die crossing the interior boundary requires a retry.

## 4. Dataset preparation and labeling

Before training, produce a versioned manifest for every scene: source path/repository revision, original file hash, decoded-pixel hash, dimensions, source capture/session/roll identifiers where known, annotation revision, dice set, lighting, camera/rig, license/permission, and assigned split. Retain originals outside the source repository. Decode historical data URLs and normalize orientation and color consistently. Hash both raw and decoded images to find repeated PNG/WebP/data-URL exports; review perceptual near-duplicates and adjacent frames manually.

Make the 138-image export the initial candidate, then compare raw result arrays, Gene's triplets, and any newly obtained exports. Do not choose a conflicting label by modification time alone. Overlay boxes on source images and manually resolve conflicts; preserve the old label and the correction's provenance. Inspect all 138 images, feasible at this size. Audit whether historical boxes enclose the upper face or the whole die, and relabel to one convention.

Canonical labels are strings `1`–`6`; one tight, axis-aligned box per readable upper face, including its pips and face boundary. Do not label side-face pips. Record unreadable/cocked/occluded dice and unsupported objects as scene metadata with regions for evaluation. Do not silently omit an unreadable die from a positive training image and teach the model that it is background: quarantine such scenes from six-class training until they have an explicit supported policy. Investigate `0` labels individually. Truly empty felt scenes are valid negatives and should have empty annotation lists.

Use a canonical upright pixel coordinate system with top-left origin and center-based `x,y,width,height`. Reject nonpositive/out-of-bounds boxes, invalid values, missing images, and mismatched dimensions. Export the schema required by the pinned Create ML version; Apple's documented directory format uses `image` and `annotations`, with center-based pixel coordinates. Verify imports and rendered overlays rather than trusting the legacy filenames. See [Apple's data-source specification](https://developer.apple.com/documentation/createml/building-an-object-detector-data-source).

### Splits and additional capture

Assign groups before augmentation: target 70% training, 15% validation, 15% historical test, stratified where possible for face/count coverage. All derivatives of a capture, burst, roll, or near-duplicate group belong to one split. When historical session identity is missing, group conservatively using visual similarity and filenames, and disclose that limitation. Disable automatic random validation and pass explicit partitions. If the corpus cannot support meaningful disjoint partitions, treat it as development data and rely on a newly captured independent test set.

Reuse old images for initial training, but new-rig evaluation is mandatory. First capture 60 development rolls on the mounted iPhone across counts 1–6 to measure domain shift and tune framing. If failures warrant it, collect an initial 300–600 additional independently arranged labeled stills over at least three sessions, aiming for at least 200 training face instances per value after curation. Include center/edge positions, all rotations, different supported dice sizes, repeated values, touching dice, shadows, and modest exposure changes; include approximately 10–20% genuinely empty scenes. Prioritize observed failure categories, not adjacent near-identical frames.

Keep separate challenge captures of hands, movement, cocked/stacked dice, glare, dark dice, and out-of-tray dice. These evaluate intervention behavior and inform future labels; they are not automatically valid negatives for the face detector. Reserve a final new-rig test session before tuning: at least 300 full supported roll clips (50 per expected count) plus 100 invalid/empty/moving/obstructed sequences. Human-label settled values, expected count, validity, and the time motion truly stops. Keep this set untouched until the candidate and thresholds are frozen. If it drives a change, it becomes development evidence and a fresh final test is required.

## 5. Training and model selection

Use Create ML's object-detector workflow on a Mac, with Apple's pretrained feature extraction/transfer-learning path available in the pinned toolchain. Keep classes and box semantics fixed. The historical `.mlmodel` is an evaluation baseline; do not assume an exported model can initialize a new training job. Archive and hash both historical snapshots before any experiment.

| Experiment | Data and recipe | Question |
| --- | --- | --- |
| A: historical model | Evaluate 8,000- and 8,020-iteration exports unchanged on the new development captures | Does the claimed best prior recognition transfer to this rig? |
| B: reproducible baseline | Train a new six-class detector on audited old training data, with explicit validation | Can we reproduce useful recognition without legacy split leakage? |
| C: targeted adaptation, if needed | Retrain the same architecture using audited old plus new-rig training images | Does setup-specific data resolve the observed failures? |

Start B/C with an 8,000-iteration budget to match the prior experiment, inspect validation metrics at available checkpoints, and extend only for a documented unresolved learning trend. Record actual algorithm, input shape, seed if supported, iteration count, training duration, macOS/Xcode/Create ML versions, dataset/split hashes, and all exposed parameters. Tool defaults must be recorded rather than assumed reproducible across versions.

Use box-aware rotation through the full 360° range, modest brightness/color changes, and realistic scale variation on training images only. Preserve pips and transform boxes correctly; avoid crops that silently drop dice or heavy blur that makes a face label unknowable. Record built-in augmentations and avoid inadvertently applying them twice. If the selected Create ML interface cannot express these transforms, generate deterministic training derivatives during preparation. Validation/test get only the fixed inference preprocessing.

Prefer the simplest candidate meeting the complete-roll gates. Report classwise precision/recall, AP at IoU 0.5 and AP across IoU 0.5–0.95, confusion among values, count errors, and exact multiset-of-values accuracy on held-out scenes. Match predictions to ground truth one-to-one. A correct total with wrong individual values is a failure. Set the score cutoff and suppression settings using validation/development sessions, with a starting score threshold of 0.90; scores are not calibrated probabilities.

Export the chosen Core ML artifact, inspect its input/output contract, class order, and included suppression behavior, and compare Mac and phone predictions on fixed fixtures. Do not apply nonmaximum suppression twice. Benchmark model size, latency, and sustained thermal behavior before considering compression or another architecture. Any export/compression change must repeat correctness evaluation. Retain a model card with provenance, training recipe, supported envelope, metrics by condition, known failures, artifact hash, and preprocessing version. Apple's [MLObjectDetector](https://developer.apple.com/documentation/createml/mlobjectdetector) is the training API reference.

## 6. Native app architecture

| Component | Responsibility |
| --- | --- |
| SwiftUI screens | Setup/calibration, count selector, live preview and overlays, result confirmation/correction, history, explicit diagnostic export |
| Capture service | Request camera permission with a purpose string; configure rear camera; deliver timestamped pixel buffers; handle interruption/backgrounding/rotation |
| Frame processor | Apply tray transform, compute motion/quality signals, schedule one inference at a time, discard obsolete work |
| Detector | Own one loaded Core ML/Vision model; return frame-stamped boxes, value labels, and scores in canonical tray coordinates |
| Roll coordinator | Own session/roll identity and lifecycle, enforce expected count and stable evidence, prevent stale/duplicate results |
| Result store | Persist confirmed values and corrections locally; provide copy/share export without requiring a game integration |

Keep capture configuration and inference off the main thread; UI updates return to the main actor. Start with inference at approximately 10 Hz and a 30 fps preview; keep a queue depth of one and drop late buffers. Use timestamp-based stability windows, not an assumed frame rate. Clear pending results when the app is interrupted and ignore completions carrying an old session/roll identifier.

Use `VNCoreMLModel`/`VNCoreMLRequest` for an exported compatible detector, following Apple's [live-capture sample](https://developer.apple.com/documentation/vision/recognizing-objects-in-live-capture). Explicitly define image orientation and crop/scale behavior. Document and test each transform: sensor orientation → upright image → tray crop/mask → padded model input → returned detection → preview aspect-fill. Vision's normalized bottom-left coordinates require conversion to the canonical top-left system. Render known fixture boxes at tray corners to detect flipped axes, padding offsets, and preview cropping mistakes.

### Roll lifecycle

`Needs setup → Ready → Armed → Moving → Settling → Proposed → Confirmed`

1. Calibration and an empty-tray reference establish `Ready`. The player selects expected count (1–6) and taps **Arm roll**. Require a clear tray before arming each new roll in this MVP; partial rerolls are later work.
2. Require observed activity after arming before entering `Settling`. A static arrangement at launch is not a new roll. A brief hand movement can be activity but cannot by itself establish a valid settled scene.
3. Estimate motion from low-resolution frame differences inside the tray, calibrated against empty-scene noise. Start with at least 0.8 seconds below the motion threshold. Any renewed motion resets the window.
4. Require exactly the selected number of nonduplicate high-score detections, all wholly inside the usable tray, consistently matched by position/overlap and value for at least 0.6 seconds and five processed observations. Start with matched IoU ≥0.5 and center drift ≤10% of face width; tune on development clips. Check weak extra detections and unexplained foreground regions against the empty reference as veto signals. They can request help but do not supply face values.
5. Quality failures, count mismatch, changed values, unmatched regions, or unstable locations reset stability and explain the problem. After five seconds without a valid proposal, offer retry/reposition/manual entry; never force an answer. A count check helps detect a missed die, but cannot prove a stack or unknown object is absent.
6. Show a frozen annotated frame, values, and total in `Proposed`. Renewed motion before confirmation invalidates the proposal. The player may confirm, edit values/count, or retry. Persist edits as manual corrections, with both original observations and final values. Manual entry must be visibly distinguished from recognition.
7. Emit one local result only after confirmation. Lock that roll ID against duplicate confirmation. Keep it in history while the player removes dice and explicitly arms another roll. Two successive rolls with identical values still have distinct IDs; unchanged dice never create repeated events.

Confirmed record: schema version, UUID roll/session IDs, confirmation timestamp, per-die values and tray boxes, total, expected count, model/preprocessing versions, observed scores, original proposed values, final values, and correction/manual-entry status. Boxes describe this observation, not persistent physical identities. Store metadata locally; retain no frames by default. Offer JSON through the native share sheet and a readable value/total string through copy. No background network transport in the MVP.

## 7. Validation and acceptance gates

Freeze the supported dice sets, rig, model, preprocessing, and thresholds before final evaluation. Use a replay harness for labeled clips through the same detector/coordinator and then repeat live sessions on the phone. Test the export and state machine separately so a good detector cannot hide lifecycle errors.

| Gate | Initial target and denominator |
| --- | --- |
| Correctness of proposals | ≥99% of proposals on the 300 supported test rolls have the exact count and multiset of values before human correction; report numerator/denominator and binomial confidence interval |
| Coverage | ≥95% of all supported test rolls yield a proposal within 3 seconds of annotated physical settling; rejected/time-out/missing proposals remain in the denominator |
| End-to-end success | ≥94% of all supported test rolls yield an exact proposal within that 3-second window; report by dice count, face value, position, and touching/separated condition |
| Intervention | Zero proposals during motion or on empty scenes; zero incorrect proposals on the 100 challenge sequences. Report uncertain/rejected categories separately; zero observed errors is not a statistical guarantee |
| Lifecycle | Zero duplicate persisted results, stale proposals after interruption, or spontaneous events on unchanged dice in replay and live tests; repeat identical-valued rolls and rapid remove/reroll explicitly |
| Speed and endurance | On the recorded reference phone, p95 inference ≤100 ms and p95 settle-to-proposal ≤2 seconds among successful proposals, plus the coverage gate above; run 20 minutes without unbounded queue/memory growth or thermal shutdown |

Also exercise camera permission denied, camera unavailable/interrupted, background/foreground, recalibration, holder movement, editing, count changes, storage failure, and share cancellation. A correction does not count as recognition success. Report detector-only metrics alongside complete-roll metrics; publish failures and latency distributions, not just averages. If a gate fails, revise the data or supported envelope explicitly before calling the prototype ready.

## 8. Implementation sequence after design review

1. **Data and rig audit:** reconcile authoritative labels, resolve `0`, verify permissions, create manifests and grouped splits, choose phone/mount geometry, collect development clips. Deliver a data inventory and labeled overlays.
2. **Model baseline:** run A/B, and C only if indicated. Deliver reproducible recipes, evaluation report, model card, and a candidate Core ML artifact. If face scale is inadequate, fix it here.
3. **Native capture and inference:** implement calibration, preview, transforms, bounded processing, and overlay diagnostics; verify fixture parity and device performance.
4. **Complete roll flow:** implement lifecycle, expected-count checks, confirmation/correction, local history, and copy/share; replay interruption and duplicate-event scenarios.
5. **Independent acceptance:** freeze the candidate, evaluate the reserved clips and live endurance sessions, document results and remaining limitations. Decide whether to collect more targeted data or expand scope only after these gates pass.

Future source layout can separate `DiceTower/` (app), `Training/` (preparation/recipes), `Evaluation/` (fixtures/reports), and model metadata. Keep large datasets, captures, checkpoints, and private exports outside ordinary Git; use a versioned artifact store with hashes and documented retrieval. None of these components or directories is implemented in PR1.

## 9. Review decisions and risks

The proposal chooses a six-class detector over pip geometry because there is a relevant native model and labeled corpus to test. Touching-dice misses or systematic value confusions may later justify a different architecture, but first measure them under the controlled rig. Black felt and an overhead mount reduce variability; they do not eliminate glare, side-face confusion, or detection omissions.

Before implementation, confirm the actual phone and dice sets, tray dimensions, access to Gene's latest labels, and permissions for any imported artifacts. The proposed count selection, clear-tray rearming, manual confirmation, and copy/share output are deliberate MVP constraints for review. Live digital game delivery and polyhedral recognition remain future work.

The repository uses GPL-3.0-only for original work. No historical source code, images, or weights are imported by this PR. Audit dataset permissions separately from repository code licenses, preserve applicable upstream notices, and record training-weight terms before distributing a trained artifact. The upstream repository's Apache-2.0 license alone does not establish provenance for every image held outside it.
