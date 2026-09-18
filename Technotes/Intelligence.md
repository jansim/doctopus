# Intelligence

Enrichment runs on either the Apple on-device model or any OpenAI-compatible
API endpoint — LM Studio, Ollama, llama.cpp, vLLM, a hosted API. Both answer
the same questions and are interchangeable, and it can be turned off entirely.

Both backends are asked the same question and produce the same
`DocumentInsight`, so routing, tagging and the inspector never know which one
ran; only `metadata.source` records it.

## What it is asked for

- A 1–2 sentence semantic summary.
- Correspondent or vendor, document category, language, and intent.
- Standard taxonomy tags and a canonical title.

Proposed tags are staged as suggestions in the inspector rather than assigned
outright — click one to accept it, or dismiss it with the ×  — and never appear
in the sidebar until accepted. A suggestion that exactly matches a tag already
in use can optionally be accepted automatically (Settings › Intelligence).
Rule-based and manually typed tags are assigned immediately, since there is
nothing to review.

The model pass can be re-triggered by hand for a selection or the whole
library, without re-running OCR or touching anything on disk. That is how a
library indexed before a model was configured gets caught up, or asked again
with a better one.

## The on-device model

`FoundationModels` is weak-linked and every call site is behind
`@available(macOS 26)` plus a runtime availability probe. Where it is
unavailable the deterministic analyzer supplies dates, correspondents, types
and titles, and the app behaves identically otherwise. Document text never
leaves the machine.

## The API model

One OpenAI-compatible `chat/completions` request shape covers every endpoint,
so there is no per-vendor code. The address is normalized however it was
pasted, and the request steps down a ladder of `json_schema` → `json_object` →
plain text, keeping whichever the endpoint actually answers.

Insisting on a schema first is what makes a local reasoning model usable:
constrained decoding stops it emitting a thinking trace at all, which on a
Gemma-class model is four seconds per document instead of thirty, and no token
budget spent on reasoning before the answer starts. Where the ladder does end
in plain text, a fenced reply, a chatty preamble and a thinking trace that
drafts JSON of its own are all still read correctly.

This backend does send document text to the endpoint you choose, which is why
it is never the default. The API key is stored in Doctopus's own index rather
than the Keychain.
