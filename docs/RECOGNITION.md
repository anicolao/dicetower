# Sensitive recognition and duplicate reporting

iOS 0.4.3 / Android 0.1.3 restore the original detection/arming sequence. The
experimental 150 ms movement-duration and two-changed-scene requirements are
removed. Movement detection does not compare dice values and cannot veto ML
based on whether the eventual arrangement resembles the previous roll.

## Detection and reporting sequence

1. Sample an upright 96×128 luminance image within the selected tray crop at
   approximately 20 Hz. Compare raw image differences globally and in 12×12 tiles.
   The score is `max(global mean / 255, highest tile mean / 255 / 3)`.
2. As before the rearming experiments, one sufficiently disturbed sample (or a
   camera-frame gap over 0.6 s) invalidates an established still scene and wakes
   recognition. iOS uses the original photo-detector pending-invalidation path
   for this recognition signal; full-resolution photo capture remains separate.
   Its 150 ms photo movement setting is not an extra recognition arming gate.
3. Require 200 ms of stillness and at least three observations. Run the on-device
   model on fresh frames, with the existing EMA/50 ms scheduling policy. Require
   two agreeing still inferences (same values and count, centers within 0.025).
4. Compare the completed conclusion with the last result emitted by this app
   process. A duplicate has the same count and values, with a one-to-one match
   whose centers differ by **less than 0.01 of the full frame on each axis**.
   Detection order, confidence and box-size jitter are ignored. An empty reading
   matches a previously emitted empty reading. Duplicate candidates do not move
   the stored baseline, preventing jitter from accumulating through discards.
5. For a duplicate, emit a metrics sample and discard the roll candidate before
   thumbnail encoding and roll-outbox enqueueing. Otherwise emit the roll and
   store its faces/event ID as the new baseline. Return to quiescence either way.

A real reroll with the same values at different positions is retained. A reroll
ending within the stated tolerance of the same values/positions is indistinguishable
under this rule and is discarded; the metric makes that decision observable.
This is conclusion-based duplicate suppression, not proof that the physical scene
is identical. Changed erroneous model predictions can still produce events.

## Duplicate telemetry

The existing `metrics/<tower>/<metricId>` stream adds three optional fields:

| Field | Meaning |
| --- | --- |
| `duplicateDiscarded` | True only on the completed-reading sample that discards a candidate. |
| `duplicateCount` | Cumulative discarded candidates in this app-process session. |
| `duplicateOfEventId` | Last emitted event matched by a discard; empty on other samples. |

A discard has `phase: quiescent`, `agreementCount: 2` and an empty `eventId`:
it did not create another roll event. `recordedAt` timestamps the decision.
Other timing/state samples carry the cumulative count and a false discard flag.
The count does not reset on ordinary motion or camera restart; an app-process
restart starts a new metrics session. Enabling sharing clears the matching
baseline so the first shared reading is not suppressed by earlier local-only
recognition. It does not reset the process counter.

Metrics use the existing durable, owner-bound outbox and exact batch retries.
Legacy metrics without these fields remain readable and retryable, including
pre-upgrade iOS outbox files. Rules keep the new fields immutable and accept no
observer writes. Metrics and rolls are separate writes, not an atomic transaction.

The app shows the session count and whether its last completed reading was
discarded. The observer shows the session count, latest visible discard time,
highlighted discard rows and links to the matching original roll. Older builds
show an unavailable count. The recent metrics window is bounded; the cumulative
count can exceed the visible discard rows. No duplicate image is uploaded.
