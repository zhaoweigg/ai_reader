# Automatic chat recovery

Leaf retries transient connection errors, incomplete streams, HTTP 408/409/429/5xx,
and known temporary provider failures. One answer has **two extra model requests**
shared across every agent round and the evidence fallback. Authentication,
permissions, subscription allowance, malformed responses, size limits and user
cancellation do not trigger recovery. Manual Retry remains available after failure.

Backoff is 0.6 / 1.2 seconds with 20% jitter. A valid `Retry-After` overrides that
delay. Recovery waits at most 8 seconds at once and 10 seconds total; a larger
provider delay is deferred to manual Retry, never shortened. Each active network
request retains the transport's existing 60-second request / 180-second resource
timeouts. Stop and Close cancel streaming and backoff immediately.

Recovery reuses the original question, captured passage and transcript. A failed
attempt's displayed text is withdrawn before the replacement starts; the existing
assistant message ID is retained. Only a terminated model round commits tool calls.
Completed local tool results stay in the transcript and are not executed again
when the following model request fails. All current agent tools read local book
or conversation data; this policy must be reviewed before adding tools with side
effects. Drafts, new selections and reading position do not replace the snapshot.

This deliberately starts a replacement inference, rather than resuming a remote
stream. Its answer can differ, and the abandoned server request can still consume
provider allowance. No unsupported response-resumption contract is assumed.
OpenAI's [retry guidance](https://developers.openai.com/api/docs/guides/rate-limits)
distinguishes pre-stream HTTP retries from failures after output begins; the latter
requires this explicit local replacement and tool-commit boundary.

On-device debug traces include model round, attempt, start/completion/failure,
backoff delay, before-output/stream stage, underlying URL error code and HTTP status
when available. Stop preserves a stopped trace. Interrupted usage is not invented
or counted as successfully reported tokens. Traces retain the existing opt-out.

Verification is intentionally scoped to deterministic recovery/agent tests,
affected provider and manual-Retry regressions, and one actual-book UI scenario
each in Pages, Scroll (agent) and PDF. UI fixtures inject a disconnection into the
production recovery path; they do not claim live provider or physical-network QA.
