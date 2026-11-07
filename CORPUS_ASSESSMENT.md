# Assessment of the November 2026 DiceCAM corpus

Inspected 2026-11-06. **Yes: this archive contains usable historical recognition-test material**, including a small pip-d6 subset. It is not a ready-made independent acceptance set for the new iPhone app. Preserve the relevant subset for evaluation before using any of it for training.

## What was checked

Inputs supplied locally: `CORPUS_NOTES.md` (Claude's summary plus earlier notes and embedded screenshots) and `dicecam-local-test-corpus-2026-11-06.zip`. Archive SHA-256:

```text
f10c97ef42e81cfe9749f7da5a687daeca7396be0704f871320095befda5149e
```

Inspected the archive inventory and current `expected.json` annotations, decoded all 491 raw stills, checked centroid and face-quad coordinate bounds, compared exact decoded-pixel hashes, and verified every ZIP entry's CRC. Visually inspected contact sheets of all 35 untyped/pip candidates with annotation overlays, representative numbered/polyhedral examples, four sampled video frames, and an incomplete-label example at full resolution. This is a structural audit and visual screening, not exhaustive ground-truth certification or a detector benchmark. No training, app implementation, or historical test suite was run.

| Inventory | Verified count |
| --- | ---: |
| Archive entries | 5,145 |
| Uncompressed bytes | 1,151,667,013 |
| Capture folders with `expected.json` | 556 |
| Folders with a raw still and expected annotations | 491 |
| Additional folder with video and expected annotations | 1 |
| Folders with annotations but neither raw still nor video | 64 |
| Raw stills | 491, all 1280×720 |
| Video frames / manifests | 300 / 1 |
| Configuration files | 491 |
| `poly-dice.json` files | 372 |
| Expected-history files | 2,934 |

The archive passes CRC verification. There are no exact decoded-pixel duplicates among the 491 stills. That does not establish independence: visually similar arrangements and successive captures exist. History files are revisions, not additional independent test cases. The 64 missing-image cases cannot be evaluated from this archive; the video-only folder explains why 65 folders lack `raw-frame.png`.

## Material relevant to pip d6 recognition

The most directly useful subset is **35 stills with 164 annotations** whose dice have no `dieType` field. Contact-sheet inspection identifies these as white, dark-pip d6 scenes on a black-felt wooden tray. They cover touching and separate dice, repeated values, different positions, and bright/low-light conditions. Their framing is close enough to the proposed setup to make them valuable early regression examples, but remains oblique webcam imagery rather than the new overhead iPhone rig.

| Face value | Recorded instances in this subset |
| --- | ---: |
| 1 | 31 |
| 2 | 26 |
| 3 | 24 |
| 4 | 30 |
| 5 | 23 |
| 6 | 30 |

Of these 35 scenes, 32 have one to six annotated dice and three have ten. These are annotation counts, not certified physical-dice counts. There are 159 upper-face quads across 34 of the scenes; the remaining five-die scene has values/centroids without quads. Deriving axis-aligned upper-face boxes from quad extrema should support detector evaluation after checking completeness and geometry. Historical `details.boundingBox` can include the whole die and must not be substituted automatically for the upper-face box.

Thirteen of these records say `manual` at the capture level and 22 say `auto-corrected`. Neither guarantees complete or correct ground truth. A concrete failure is `2026-06-22T22-52-55-957Z`: the image visibly contains five dice with upper values 4, 6, 4, 1, 5, but `expected.json` contains only one die, value 4. Exclude or correct it before count/recall scoring. After excluding this known partial record and the three ten-die scenes, **31 scenes remain as candidates within the MVP's count range**, still requiring detailed review. The small and uneven count coverage cannot substantiate the MVP acceptance targets.

The lack of a `dieType` field is an archive-specific discovery aid, not a general definition of pip dice. Later records use `polyhedral` and `shape: d6` for examples that must be visually distinguished from pip d6; a value in 1–6 or shape `d6` is insufficient to select the MVP task.

## The rest of the still corpus

Across the 491 available stills there are 4,689 recorded dice: 164 without a type, 421 marked `numbered`, and 4,104 marked `polyhedral`. These larger groups can support future tasks and challenge evaluation for unsupported dice. They must not be mixed into the six-class pip model merely because some values are between 1 and 6. In particular, a zero on a percentile/numbered die has different semantics from an unexplained `0` in the old pip corpus.

Annotations vary considerably: most dice have only centroids plus type/value metadata; only 511 dice across the available stills have face quads. All recorded still centroids and available quad vertices pass image-bound checks, but that says nothing about label correctness. Some records flag provisional or transplanted labels. Among the available-image annotations, 292 dice say `auto-label` and 260 say `model-label`; a capture-level `manual` label therefore cannot establish independent human ground truth for every die. `poly-dice.json` contains extracted predictions/features and is not interchangeable with audited expected annotations.

These examples are useful for testing whether the app requests intervention around unknown dice. They are not automatically negative training images: supported-looking faces can occur in mixed scenes, and six-class detection alone cannot guarantee rejection of every unknown object.

## Video: useful, but limited

The single recording is `2026-05-17T23-53-22-014Z-d2da`. Its manifest identifies a Logitech C920 webcam at 1280×720. All 300 referenced frames are present. Timestamps span approximately **95.27 seconds**, and the largest inter-frame gap is approximately **9.04 seconds**. The manifest's overall `fps` is about 3.14, but spacing varies considerably; replay must use the actual timestamps.

The capture has one expected annotation record for five dice, all value 2. Sampled frames at indices 0, 100, 200, and 299 show essentially the same settled arrangement. This is promising for stationary-result stability and duplicate-event checks, and for testing behavior across dropped-frame gaps. It is not evidence of 300 independent rolls. There are no per-frame values, validity labels, roll boundaries, or settling-time annotations in the supplied expected record. Inspect the complete sequence before extending its labels to every frame. It cannot currently score settle-to-proposal latency or moving-scene rejection; an armed pipeline should also avoid generating a new roll from an already stationary scene.

## Recommended use in DiceTower

1. Freeze the archive by hash and make an explicit list of candidate capture IDs. Preserve source annotations/history. Do not train on the pip subset while also calling it held-out evaluation data.
2. Review each candidate at full resolution for every physical die, its actual upper value, quad placement, readability, and valid/invalid scene status. Correct the known incomplete case and retain correction provenance. Add missing quads only where needed for localization metrics.
3. Group near-duplicates and captures from the same session before allocating data. Check similarity against the historical training corpus too; this audit has not established cross-corpus independence. Since these examples were used to develop the previous detector, describe them as historical regression data rather than an unbiased measure of that detector's generalization.
4. Use audited pip stills for value/count regression and, where geometry is complete, upper-face localization. Report ten-die and low-light cases separately from supported-envelope scores. Reserve the video for the lifecycle checks its verified content can support.
5. Retain numbered/polyhedral material separately for future work and labeled challenge scenes. Continue collecting an independent, fully labeled set from the actual iPhone rig for the MVP acceptance gates.

The notes refer to branch `gpu-frontchain-diagnostics` at `0f7f4d5`. Neither that branch nor abbreviated commit resolved in the accessible `egirard/DiceCAM` repository during this inspection. Therefore the notes' claims about pushed test code, fixture coverage, and historical test results remain unverified here. The archive itself is enough to inspect and curate the data without that code.

Only this assessment and design updates belong in the documentation PR. The original notes, embedded screenshots, ZIP, extracted images, and temporary audit scripts remain local; no raw corpus or historical implementation is imported. Confirm redistribution permissions and artifact hosting separately before publishing images or labels.
