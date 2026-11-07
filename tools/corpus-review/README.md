# Local golden-master review

## Frozen test results

```sh
python3 tools/corpus-review/results.py --port 8767
```

Open **http://127.0.0.1:8767** to inspect the frozen test failures (default), all
ten test photos, or passing cases. Compare the fine-tuned and unchanged models;
toggle approved truth and model overlays, enlarge the image, and inspect each
face's full-resolution crop, expected/predicted values, confidence, and overlap.
Extra detections and missed faces are listed separately. Below-cutoff detections
are available as a diagnostic list. Thresholds and metrics remain frozen. This
viewer does not alter approved golden masters or run inference. Review notes save
separately under the experiment's `review-notes/` directory. Pending visual label
findings can be supplied in `review-findings.json`; neither notes nor findings
change the frozen scores. Unsaved notes prompt before leaving a photo.

## Label approval

Review the November 6 iOS capture session at **http://127.0.0.1:8765**.

```sh
python3 tools/corpus-review/server.py --data local-data/rig-review --port 8765
```

The server uses only Python's standard library, binds to loopback, and serves only
the review UI and selected corpus images. Photos, proposals, and review state stay
in ignored `local-data/`. No external services or browser storage are required.

Each capture shows its oriented photograph, numbered upper-face box overlays,
enlarged dice crops, proposed face values, count, sum, and scene-specific analysis.
Select a box to move it or resize its corner handles. Draw missing boxes, remove
extra boxes, change face values, and add notes. Zoom and full-resolution views
help distinguish upper-face pips from side-face pips. Use **Approve & next** only
after checking all dice and boxes. **Save edits as pending** retains corrections
without approving; **Flag for revision** records a problem. Arrow keys navigate.
Unsaved changes prompt before leaving. Multiple-tab saves use revision checks.

Approval writes `local-data/rig-review/reviews/<capture-id>.json` and
`local-data/rig-review/golden-masters/<capture-id>/expected.json`. Changing an
approved record back to pending or flagged withdraws its current golden master.
An append-only `review-history.jsonl` preserves prior decisions. `/api/approved`
exports only approved records; proposals never enter this export automatically.
Keep the entire local-data directory when moving or backing up the corpus: master
image references point to the normalized images two directories above them.

Original JPEGs and capture metadata are preserved in the extracted source export.
Coordinates are **EXIF-normalized, top-left image pixels, `[x, y, width, height]`**;
these portrait images are 3024 × 4032. Boxes should enclose the visible upper face,
not the entire cube. Original and normalized-image SHA-256 hashes distinguish
the source camera file from the oriented review derivative.

The initial 50 proposals contain 245 dice and one empty-tray negative. They were
created with white-region segmentation, visual inspection, and manual correction
of merged, shadowed, and clipped detections. They are **not the previous ML model's
predictions**, and are not approved ground truth. All captures belong to one
session; dataset allocation remains unassigned so this session is not silently
mixed across training and evaluation.

To prepare another extracted iOS export, install Pillow and OpenCV in a virtual
environment, then run `prepare.py SOURCE OUTPUT`. This particular segmentation
ROI is specific to the November 6 rig and must be changed for different framing.
Preparation emits unlabeled proposals; it is not a general labeling model. Do not
rerun preparation over an existing curated corpus. This session's manual curation
scripts and proposals are preserved alongside its local data.

Validation:

```sh
python3 -m unittest discover -s tools/corpus-review -p 'test_*.py'
node --check tools/corpus-review/web/app.js
```
