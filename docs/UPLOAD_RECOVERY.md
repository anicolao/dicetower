# Independent uploads and held-record recovery

iOS 0.4.4 / Android 0.1.4 fix a queue starvation bug. Previously, roll files were
sorted by UUID filename and the first decoding/network/server error aborted the
entire pass. Later UUIDs never ran, and metrics (processed after rolls) never ran
either. New random UUIDs sorting before the failing record could still upload,
making a fixed blockage look like intermittent recognition or connectivity.

The field investigation found 65 subsequent uploaded event IDs all sorting before
`A008…`, while the metrics stream remained stuck at 10:00:43 Toronto time. This
strongly supports the failure mode, but the physical phone was disconnected and
its particular failing file could not be inspected. The exact original rejection
reason is therefore unconfirmed. This fix exposes it instead of hiding every
failure behind a generic retrying message.

## Delivery policy

- Decode/identity/acknowledgement failures on individual records and permanent
  HTTP 400/403/413/422 responses, or a 401 rules rejection confirmed after an
  authentication refresh, move that record into a **Held** directory. Original
  bytes and a bounded reason/filename are preserved. No failed payload is deleted.
- Continue to later roll files. Metrics get an independent attempt even if the
  roll pass encounters a transient network or authentication failure.
- Keep timeouts, offline errors, unconfirmed/authentication HTTP 401, HTTP 429/5xx and cancellation pending for
  retry. The global authenticated tower-identity check still fails safely before
  sending another owner's data. Per-record owner mismatches are held, never retargeted.
- If a metrics batch is permanently rejected, bisect it until rejected individual records are identified;
  acknowledge healthy sub-batches and hold only rejected samples. Exact immutable retries
  and conditional roll creates remain in use, preserving lost-ACK idempotency.
- Stop-sharing checks still stop transmission and preserve both pending and held
  files. Disk failures leave original files intact and surface an error.

On upgrade, previously blocked pending records remain in their original queue and
are retried automatically. Good historical records behind a blocker can finally
arrive. Their original capture timestamps are retained, so they may appear in
older history rather than as the latest roll. Held records require inspection or
a fix before retrying. **Retry held uploads** in the sharing screen restores their
original bytes/IDs to the pending queue; a still-invalid record is held again.
This control never rewrites or silently repairs a payload.

RTDB can return HTTP 401 for security-rule validation failures as well as expired
tokens. The client refreshes authentication once before treating a repeated
`Permission denied` response as a rejected record. Other authentication failures
remain retryable. This distinction is covered by regressions and live QA.

## Upload health

The sharing status shows pending roll/metric counts, held count, record-ID prefix
and the error. Recognition labels mean the local reading is settled, not that a
server acknowledgement has arrived.

Two optional, immutable fields extend the existing metrics schema:

| Field | Meaning |
| --- | --- |
| `uploadHeldCount` | Records retained in the held queue on this installation. |
| `uploadIssue` | Latest bounded held-record issue, without credentials or request URLs. |

New samples carry this status. A held-status change also queues a fresh status
snapshot so a quiescent recognizer can report recovery/problems without running
another inference. Status snapshots have an empty `eventId`, a false duplicate
discard flag, and retain the cumulative inference/duplicate counters.
The observer shows the count and issue alongside recognition metrics. Older
builds show upload health as unavailable. Telemetry itself still requires a
working network; local held state survives app/process restarts.

## Verification

Regression tests cover valid UUIDs before and after bad records, malformed JSON,
permanent rejection, rejected metrics-batch isolation, transient/offline/lost-ACK
retries, owner protection, stopped sharing, and byte-for-byte held-record restore.
The explicit Debug-simulator live-QA flag `-upload-poison-demo` seeds two valid
rolls on either side of an unreadable UUID, an unreadable metric, and a metric
whose settlement value deliberately violates deployed rules. It is paired with
`-cloud-demo` and excluded from physical-device/Release builds.
