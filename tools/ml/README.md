# Approved rig training experiment

Artifacts and complete scores live locally in `local-models/rig-2026-11-06/`.
The source captures, review decisions, and golden masters remain in ignored
`local-data/rig-review/`. No dataset or trained model is published by these tools.

`prepare_rig.py` snapshots approved reviews, verifies normalized-image hashes,
groups similar arrangements without using face values, and deterministically
allocates 30/10/10 scenes. Face values and lighting strata balance the split.
Quarter rotations and exposure/contrast perturbations apply only to training.
All images share a capture session, so test results describe within-session
generalization. Keep collecting separate sessions, dice sets, and varied counts.

The selected historical model is the native Create ML six-class TinyYOLO export
from its 6,000-iteration checkpoint. Create ML's public `MLObjectDetector` APIs
cannot initialize a new dataset from those custom weights. `warmstart.py` loads
the actual exported convolution and batch-normalization weights into an equivalent
PyTorch network, verifies scores/boxes against Core ML before training, and
fine-tunes its last three convolution layers. Earlier layers and all batch-norm
statistics remain frozen. This is a weight fine-tune of the existing detector;
it does not substitute a different model architecture. Exports replace weights
inside the original Core ML graph, preserving decoding, class labels, and NMS.
No PyTorch-to-Core-ML graph conversion is involved.

```sh
python3 -m venv local-models/rig-venv
local-models/rig-venv/bin/pip install -r tools/ml/requirements.txt
local-models/rig-venv/bin/python tools/ml/prepare_rig.py --output local-models/rig-new-run
local-models/rig-venv/bin/python tools/ml/warmstart.py --root local-models/rig-new-run --steps 1200
xcrun swiftc -O tools/ml/predict.swift -o local-models/rig-new-run/predict
```

Fine-tuning is deterministic at the split/augmentation-seed level; GPU training
is not promised bit-for-bit reproducible. The 2.8 PyTorch package emits a
coremltools compatibility warning (latest tested version 2.7); this workflow uses
protobuf weight I/O rather than conversion, and verifies native exported inference.

Input preprocessing is part of the model contract: apply EXIF orientation to RGB,
crop the fixed rig region `(20,140)-(700,1080)` in a 900×1200 reference frame, then
aspect-fit to 416×416 with black padding. These are fixed tray-edge coordinates,
not crops calculated from ground-truth dice. The manifest records exact integer
crop/resize/padding transforms for each image and maps predictions back to the
oriented original. Use prepared square images when inspecting the model in Xcode.

Validation, never test, selects checkpoints and the score cutoff. The ranking is
exact value multisets, then class-correct localization F1 at IoU .5. Tied
checkpoints retain the earlier result. Every missing or extra die counts as an
error; inference receives no expected dice count. Swapped locations can pass a
value-multiset check, so fully localized correct scenes are reported separately.

`predict.swift` runs the exported model through native Vision. Its detection score
is **observation confidence × label confidence**. Vision normalizes label scores;
filtering on label confidence alone admits near-zero-objectness detections.
This follows [Apple's VNRecognizedObjectObservation documentation](https://developer.apple.com/documentation/vision/vnrecognizedobjectobservation).
The old prototype's label-only evaluation results must not be compared directly
with the corrected scores here.

```sh
DICETOWER_EVAL_SPLIT=validation local-models/rig-new-run/predict MODEL.mlmodel local-models/rig-new-run validation.json prepared
local-models/rig-venv/bin/python tools/ml/evaluate_rig.py validation.json --root local-models/rig-new-run
```

Freeze model identity, hashes, confidence threshold, preprocessing, and selection
reason in `selection.json` before opening test predictions. `evaluate_rig.py`
requires that file before reporting test scores. Do not tune a checkpoint or
threshold on test failures; collect a new held-out set for the next iteration.

Owner-confirmed truth corrections can be scored without new inference or
overwriting the original evaluation:

```sh
local-models/rig-venv/bin/python tools/ml/evaluate_rig.py saved-test-predictions.json --root EXPERIMENT --cutoff FROZEN_CUTOFF --truth-manifest AUDITED_MANIFEST --suffix=-audited-v2
```

Preserve the original manifest and selection hash, record confirmation provenance
and the new manifest hash, and identify the truth version when reporting results.

```sh
local-models/rig-venv/bin/python -m unittest discover -s tools/ml -p 'test_*.py'
```
