# Intelligence

Enrichment runs on either the Apple on-device model or any OpenAI-compatible
API endpoint — LM Studio, Ollama, llama.cpp, vLLM, a hosted API. Both answer
the same questions and are interchangeable, and it can be turned off entirely.

Both backends are asked the same question and produce the same
`DocumentInsight`, so routing, tagging and the inspector never know which one
ran; only `metadata.source` records it — `remote:`, or `vlm:` where the model
was shown the page as well.

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

## Vision models

Where the endpoint is a vision model, each document's first page is sent as an
image alongside its text (Settings › Intelligence › Page Image). The letterhead,
a logo, a stamp or the layout of a table then count towards the answer, and a
scan whose text layer is noise is still classified — a document OCR found
nothing in is asked about at all, where the text-only path skips it.

The page is rasterized to a colour JPEG, longest edge configurable and 1,024 px
by default, with the page's own `/Rotate` and a photo's EXIF orientation
applied, and sent as an `image_url` content part beside the text. The page count
is spelled out in the prompt, so a model shown page 1 of 12 does not summarize
as though the rest were missing. The text is still the whole document: the image
adds what OCR drops, it does not replace it.

A model that cannot see refuses the request, and the refusal is recognized from
what the server says rather than from a status code — including the case where
an endpoint rejects every response format only while an image is attached.
Doctopus then falls back to text alone for the rest of the session.
