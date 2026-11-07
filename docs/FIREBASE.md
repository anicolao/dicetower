# Named towers and live roll streams

The observer lives at <https://anicolao.github.io/dicetower/>. Each tab selects its
own tower using `?tower=<Firebase UID>`. Selection is not stored globally, so tabs
can watch different towers. The sidebar lists the 200 most recently active named
towers; a saved tower URL still works outside that list. Display names need not be
unique: a short ID distinguishes towers with the same name.

## Using the app

On first launch, name the tower and choose **Start sharing rolls**, or keep capture
local. Camera recognition runs without auto photo capture. The sharing row opens
rename, stop-sharing, and a link to this tower's observer. The phone stays at 1× in
portrait. Check the tray crop and all face predictions before trusting a roll.

In version 0.3, a still scene agreed across three inference results before publication; version 0.4 uses the faster policy described below. An
unchanged reading does not keep publishing. Observed movement rearms the publisher,
so another roll with identical values still creates a new roll event. A changed,
stable prediction without new movement creates a `recognitionChanged` event with
the same roll ID. Small box jitter and confidence changes do not create events.
An empty scene can publish a zero-dice reading; it is an observation, not proof
that the tray is empty. These are experimental model conclusions, not approved
corpus labels or player-confirmed game results.

A published event contains a JPEG thumbnail from the *same video frame* as its
boxes, upper-face values/confidences, count/total, capture timestamp, server receipt
timestamp, model hash and roll/event IDs. The thumbnail is at most 384×512, JPEG
quality 0.6, with a 74KB encoded-JPEG limit. Full original photos stay local and
continue to export as unlabeled corpus data.

Sharing is visible to any anonymous observer. Stopping sharing stops new uploads;
published history remains visible. Events have no automatic expiry in this
prototype. Anonymous identities are not recoverable on another device; this is
not a user-account or cross-device tower-management system.

## Firebase resources

- Project: **dicetower-anicolao**, display name **DiceTower**.
- Realtime Database: **dicetower-anicolao-default-rtdb**, **us-central1**.
- Web app: **DiceTower Observer**, app ID `1:668082623324:web:4c047e3a19d643306ba799`.
- Anonymous authentication is configured in `firebase.json` and deployed using
  `firebase deploy --only auth,database`.
- `firebase/client-config.json` and the identical native `FirebaseConfig.json`
  contain public client configuration. They contain no administrative credential.
  Authorization is enforced by the deployed database rules.
- Thumbnails are inline event data. This version needs no Cloud Storage bucket,
  Cloud Function, application server, or billing-linked service.

```text
towers/<owner anonymous UID>/
  schemaVersion, name, createdAt, updatedAt, sharing
rolls/<owner anonymous UID>/<event UUID>/
  schemaVersion, eventId, rollId, kind
  capturedAt, receivedAt          # Unix milliseconds
  modelSHA256, experimental
  count, total
  dice/<index>/value, confidence, box/{x,y,width,height}
  thumbnail                       # data:image/jpeg;base64,...
```

Box coordinates are normalized top-left coordinates in the complete upright frame.
Capture time controls ordering, even if offline events arrive later. Events with
identical timestamps are ordered by ID. The observer loads 50 recent events, then
pages backward in batches of 50 while listening to the latest 50. Malformed events
are rejected by the UI rather than displaying inconsistent totals or unsafe image
URLs. Recent live data and paged history merge by immutable event ID.

The native app uses Firebase's documented [anonymous-auth and refresh REST APIs](https://firebase.google.com/docs/reference/rest/auth/)
and [Realtime Database REST API](https://firebase.google.com/docs/database/rest/save-data),
using URLSession with 20-second request timeouts. Its anonymous UID and refresh
credential persist in Keychain, accessible after first unlock on this device only.
Concurrent sign-in attempts share one task. Tokens are never written to logs,
UserDefaults, corpus ZIPs or Git. The observer uses the modular Firebase JS SDK and
a persistent anonymous browser identity, with no account/sign-in screen.

Every queued event is atomically written to Application Support before an upload.
The outbox survives app restarts and network failures. A foreground worker retries
every 15 seconds and updates the tower heartbeat about once a minute. Uploads use
conditional creation (`If-Match: null_etag`); an existing record after a lost ACK is
acknowledged without another event. Old queued data never changes tower identity.
The outbox is separate from corpus exports. Uploading is suspended while sharing
is off; the app does not claim background-camera operation. An abrupt suspension
can lose an observation that has not yet reached the outbox.

Rules require authentication, bind each writable tower/stream to its owner's UID,
validate bounded payloads and dice fields, and make events append-only. Anonymous
observers cannot overwrite another tower or its events. Listing towers and event
streams requires bounded indexed queries; direct authenticated reads of individual
profiles/events support links and idempotent acknowledgments. The UI independently
verifies exact face count and sum. No client supplies privileged credentials.

## Develop and deploy

```sh
npm ci
npm run dev                       # http://127.0.0.1:8770
npm test                          # pure event/viewer tests
npm run test:rules                # requires Java 21; Auth + RTDB emulators
npm run build                     # static assets in apps/web/dist
npm run firebase:deploy           # existing Firebase CLI account required
npm run deploy:pages              # publish built assets to gh-pages
```

GitHub Pages serves the `gh-pages` branch root; `.nojekyll` prevents Jekyll asset
rewriting. The deploy script preserves the prior deployment history, commits the
built assets and records the source commit in `version.json`. Its Git push uses
the existing Git credential helper. After a deploy, check the Pages build status
and the published `version.json`. Source changes remain reviewable in their PR;
the published assets have their own branch.

Native build/test commands remain in `apps/ios/README.md`. Simulator collection
fixtures are offline by default; `-capture-demo -cloud-demo` explicitly enables
live Firebase QA. The optional live registration UI test also requires
`DICETOWER_LIVE_QA=1` in the test runner environment, and uses the `QA Simulator Rig`
name. Remove only the known QA identities/events after live checks; never clear
the database as part of a test. The normal CI uses only emulators and pure tests.

## Fast recognition and the metrics stream (0.4)

Recognition has a fixed **200 ms** image-stillness window. The adjustable settling
control in Camera settings now explicitly applies to saved photographs; existing
photo preferences remain intact. Motion analysis samples at approximately 20 Hz,
subject to camera frame rate. The short stillness window has no hidden five-frame
minimum: three or more observations can satisfy it when 200 ms has elapsed.

The recognizer uses a single in-flight request and retains only the latest frame.
Two consecutive still-frame results must agree on face values, count and positions
(centers within 0.025 normalized units, independent of detection ordering). A
mismatch restarts agreement at one. Motion invalidates both pending work and the
candidate. After the second agreeing result, the app reports once and becomes
**quiescent**: it stops ML requests and timing samples until confirmed motion, a settings
change, an explicit sharing setup, or camera restart rearms it. Empty detections
can agree too; they remain an experimental zero-dice observation. New builds do
not continuously revise a motionless, already-reported scene.

In iOS 0.4.3 / Android 0.1.3, the original sensitive detection/arming sequence is
restored. A single image disturbance can wake recognition again. Duplicate
conclusions are filtered **after** recognition, using the last emitted dice
values and centers (within 1% on each axis, independent of ordering/confidence).
Each discard produces a timing-stream sample and increments a process-session
counter, without creating a roll event or uploading another thumbnail. The exact
sequence, tolerance, sharing/reset behavior and limitations are specified in
[RECOGNITION.md](RECOGNITION.md).

Each completed Vision request is timed using monotonic system uptime. Its EMA is
initialized from the first measurement and updated as `0.2 * last + 0.8 * EMA`.
The target start-to-start interval is `max(50, ceil(EMA_ms / 50) * 50)` milliseconds.
A timer wakes at the next deadline and uses the latest unused camera frame. A
frame is never inferred twice, and requests never overlap. If full frame work
outlasts the target, the next wake moves to the following 50 ms clock boundary.
Camera availability and OS scheduling can make actual starts later. Model loading
is excluded from these measurements; first-request Vision warm-up is included.

A separate stream at `metrics/<tower UID>/<metric UUID>` contains per-inference
and state-transition samples. These do not contain images or dice conclusions:

| Field | Meaning |
| --- | --- |
| `inferenceMs` | Elapsed time for Vision/Core ML request execution. |
| `emaInferenceMs` | EMA of request execution time, alpha 0.2. |
| `processingMs` | Crop/resize/render, request execution and result decoding; excludes model loading, thumbnail encoding, disk and networking. |
| `intervalMs` | Rounded target interval, a multiple of 50 ms. |
| `inferenceCount` | Completed requests in this app process, including invalidated results whose timing is still useful. |
| `agreementCount` | Consecutive accepted still-frame agreements: 0, 1, or 2. |
| `settleMs` | Fixed recognition settlement requirement: 200. |
| `phase` | `active`, `quiescent`, `paused`, or `error`. |
| `duplicateDiscarded` | Optional boolean: this sample discarded a completed duplicate reading. |
| `duplicateCount` | Optional cumulative discard count in this app-process session. |
| `duplicateOfEventId` | Optional original event ID matched by the discard; empty on other samples. |

Samples also carry schema version, metric ID, app-process session ID, wall-clock
`recordedAt`, and an `eventId` when associated with a reported recognition.
The app displays every timing/count/state field above its camera preview. The new
web panel shows the same values, a sample table, and timing beside matching roll
cards. Older apps keep working and simply have no timing stream.

Metrics have their own durable outbox subdirectory and are uploaded in batches of
up to 100. Samples are immutable; exact retries of the same batch are accepted.
Only the owning anonymous UID can write them; authenticated observers use bounded,
indexed queries. An immediate drain follows data arriving during an upload, so a
final idle sample does not wait for the 15-second network-recovery timer. No new
per-inference samples are generated while ML is idle. Sharing controls apply to
both images/results and metrics. Published metrics, like published roll history,
remain visible when sharing stops.

### PR web previews

Preview deployments preserve production and other previews:

```sh
DICETOWER_WEB_BASE=/dicetower/previews/pr-5/ npm run build
npm run deploy:pages -- pr-5
```

The preview then lives at `https://anicolao.github.io/dicetower/previews/pr-5/`.
Use the actual PR number. Both views read the same Firebase project, so the new
TestFlight build's metrics can be inspected in the preview while production stays
on the reviewed web version. `version.json` in each deployment records its source
commit. A production deploy preserves the `previews/` directory.
