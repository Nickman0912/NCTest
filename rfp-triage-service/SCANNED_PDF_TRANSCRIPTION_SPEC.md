# Scanned PDF Transcription for RAG Ingestion — Implementation Spec

> **Audience:** an implementing agent (this was written to be handed to
> DeepSeek, but any competent agent or developer can execute it).
> Plain text and code only — no images, no diagrams, nothing that requires
> visual rendering.
>
> **Project root:** `C:\Users\NicolasClemens\FuryDev\NCTest\NCTest`
> **Service directory:** `rfp-triage-service/` (all edits below are relative
> to that directory unless stated otherwise).

---

## 1. Goal

Scanned/image-only PDFs (common in construction bid packages) are currently
**skipped** by the RAG ingestion path, so the Deep Dive assistant cannot
answer questions about them. This change makes ingestion **transcribe**
scanned PDF pages with a cheap vision model, then chunk and embed the
transcription exactly like a text-layer document.

After this change:

- A scanned PDF uploaded via the Deep Dive UI, or arriving as an email
  reference doc, is transcribed and indexed instead of skipped.
- The ingest job reports a distinct, honest status so the user knows the
  document was transcribed from images (lower fidelity than a real text
  layer).

## 2. Non-Goals

- Do NOT change the **triage** vision path (`extract()` /
  `_analyze_openrouter` vision branch). That path already handles small
  scanned ITBs for fact extraction and stays as-is.
- Do NOT change chunking, embedding, retrieval, or the LWC. Transcribed text
  flows through the existing `rag.ingest()` unchanged.
- Do NOT add new dependencies to `requirements.txt`. Everything needed
  (`pypdfium2`, `Pillow`, `openai`, `PyMuPDF`) is already pinned there.
- Do NOT introduce parallel page processing. Sequential transcription inside
  the existing background thread is correct and keeps cost/ordering simple.

## 3. Critical Model Constraint (read this first)

**DeepSeek's chat models are TEXT-ONLY. They cannot see images.** Do not
route transcription to DeepSeek. The transcription model MUST be
vision-capable.

Default the transcription model to `google/gemini-2.5-flash` (vision-capable,
cheap, already used elsewhere in this codebase for extraction). Make it
configurable via a new env var `TRANSCRIPTION_MODEL`. Gemini 2.5 Flash is
reachable through the existing OpenRouter gateway using the OpenAI-compatible
client, the same way every other LLM call in this service is made.

Vision input format (same pattern already used in
`analyzer._analyze_openrouter`): each page is a base64 PNG passed as an
`image_url` content part with a `data:image/png;base64,...` URL.

## 4. Files to Modify

1. `rfp-triage-service/extractor.py` — add a transcription function and a
   way to render ALL pages (not just the first 15).
2. `rfp-triage-service/main.py` — call transcription in `_run_ingest` when
   text extraction comes up short; also handle scanned reference docs in
   `_process_email`.
3. `rfp-triage-service/config.py` — add `TRANSCRIPTION_MODEL` and a page cap.
4. `rfp-triage-service/test_email_processing.py` — update the existing
   "skips vision docs" test (behavior changes) and add coverage.

No new files are required. No Salesforce/Apex/LWC changes are required.

---

## 5. Detailed Changes

### 5.1 `config.py`

Add near the other model settings (after the `VISION_MODEL` line):

```python
# TRANSCRIPTION_MODEL: vision model used to transcribe scanned PDF pages to
#   text for RAG ingestion. MUST be vision-capable (DeepSeek chat models are
#   text-only and will NOT work here). Gemini 2.5 Flash is the cheap default.
TRANSCRIPTION_MODEL = os.environ.get(
    "TRANSCRIPTION_MODEL", "google/gemini-2.5-flash")
# Cap pages transcribed per document so a runaway scan can't blow up cost or
# the background thread's runtime. Generous for real spec books.
TRANSCRIPTION_MAX_PAGES = int(os.environ.get("TRANSCRIPTION_MAX_PAGES", "200"))
```

### 5.2 `extractor.py`

Add a module constant near the top (next to `MIN_TEXT_CHARS` /
`MAX_VISION_PAGES`):

```python
# DPI for transcription rendering. 150 is legible for body text; matches the
# existing vision-path render scale.
TRANSCRIPTION_DPI = 150
```

Add a full-document page renderer. The existing `_render_pages()` is capped
at `MAX_VISION_PAGES` (15) and is shared with the triage path — do NOT change
its behavior. Instead add a sibling that renders up to a caller-supplied
limit:

```python
def _render_all_pages(file_bytes: bytes, max_pages: int) -> list[str]:
    """Render up to max_pages PDF pages to base64 PNGs (for transcription)."""
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(file_bytes)
    images = []
    total = len(pdf)
    for i in range(min(total, max_pages)):
        bitmap = pdf[i].render(scale=TRANSCRIPTION_DPI / 72)
        img = bitmap.to_pil()
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        images.append(base64.b64encode(buf.getvalue()).decode())
    if total > max_pages:
        logger.warning("PDF has %d pages; only first %d transcribed",
                       total, max_pages)
    pdf.close()
    return images
```

Add the transcription entry point. Transcribe **one page per request** so a
single bad page or a context limit never fails the whole document, and so the
combined output preserves page order:

```python
TRANSCRIBE_PROMPT = (
    "Transcribe the text on this scanned document page exactly as it "
    "appears, preserving reading order. Output plain text only: no "
    "commentary, no markdown fences, no description of the page. If a page "
    "region is illegible, omit it rather than guessing."
)


def transcribe_scanned_pdf(file_bytes: bytes, max_pages: int,
                           model: str) -> str:
    """Transcribe a scanned/image-only PDF to text via a vision model.

    One page per request, in page order, so a single failure can't lose the
    whole document. Returns the concatenated transcription. Raises ValueError
    if nothing usable was produced.
    """
    import config
    from openai import OpenAI

    pages = _render_all_pages(file_bytes, max_pages)
    if not pages:
        raise ValueError("no pages rendered for transcription")

    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)

    page_texts = []
    for i, img in enumerate(pages):
        try:
            resp = client.chat.completions.create(
                model=model,
                max_tokens=2000,
                messages=[{
                    "role": "user",
                    "content": [
                        {"type": "text", "text": TRANSCRIBE_PROMPT},
                        {"type": "image_url",
                         "image_url": {"url": f"data:image/png;base64,{img}"}},
                    ],
                }],
            )
            text = (resp.choices[0].message.content or "").strip()
        except Exception:
            logger.exception("Transcription failed on page %d", i)
            text = ""
        if text:
            page_texts.append(text)
        logger.info("Transcribed page %d/%d (%d chars)", i + 1, len(pages),
                    len(text))

    combined = "\n\n".join(page_texts).strip()
    if not combined:
        raise ValueError("transcription produced no text")
    return combined
```

Note: `base64`, `io`, and `logging`/`logger` are already imported at the top
of `extractor.py`. `config` and `OpenAI` are imported lazily inside the
function to match the existing pattern in this codebase (see `rag._embed`
and `analyzer._analyze_openrouter`, which also import `OpenAI` lazily and
build the client with the same `base_url`).

### 5.3 `main.py` — `_run_ingest` (the main fix)

Current behavior (lines ~190–200): if `extract_text_only` returns fewer than
`MIN_TEXT_CHARS`, the job is set to `skipped` and returns.

Replace that skip branch with a transcription attempt. Keep everything else
identical. The new logic:

```python
    try:
        text = extractor.extract_text_only(file_bytes, filename)
        transcribed = False
        if len(text) < extractor.MIN_TEXT_CHARS:
            # Scanned/image-only PDF: transcribe via vision model instead of
            # skipping. Only PDFs can be scanned, so guard on the extension.
            if not filename.lower().endswith(".pdf"):
                rag.set_job(key, rfp_id, filename, "skipped",
                            reason="no extractable text layer")
                return
            logger.info("No text layer in %s; transcribing scanned pages",
                        filename)
            rag.set_job(key, rfp_id, filename, "processing")
            text = extractor.transcribe_scanned_pdf(
                file_bytes, config.TRANSCRIPTION_MAX_PAGES,
                config.TRANSCRIPTION_MODEL)
            transcribed = True
            if len(text) < extractor.MIN_TEXT_CHARS:
                rag.set_job(key, rfp_id, filename, "skipped",
                            reason="scanned document; transcription yielded no usable text")
                return
        chunks = rag.ingest(rfp_id, filename, text)
        logger.info("Ingested %s -> %d chunks (transcribed=%s)",
                    key, chunks, transcribed)
        status = "transcribed" if transcribed else "ingested"
        rag.set_job(key, rfp_id, filename, status, chunks=chunks)
    except ValueError as e:
        logger.warning("Could not ingest %s: %s", filename, e)
        rag.set_job(key, rfp_id, filename, "skipped", reason=str(e))
    except Exception:
        logger.exception("Ingestion failed for %s", filename)
        rag.set_job(key, rfp_id, filename, "error", reason="ingestion failed")
```

Important details:

- `config` is already imported at the top of `main.py` (it is used as
  `config.DATABASE_URL`, `config.TRANSCRIPTION_MAX_PAGES`, etc.). No new
  import needed.
- The new `"transcribed"` status is returned by `/ingest-status` as-is (the
  endpoint just returns the job dict). Verify the LWC's `_pollIngest` treats
  it as a terminal/success state. If the LWC only recognizes `"ingested"`,
  either (a) also accept `"transcribed"` in the LWC, or (b) simpler and
  recommended: keep the job status as `"ingested"` and instead encode the
  transcription in the `reason` field, e.g.
  `rag.set_job(key, rfp_id, filename, "ingested", chunks=chunks,
  reason="transcribed from scanned pages")`.
  **Prefer option (b)** — it requires no LWC change and no Salesforce
  redeploy. Use option (b) unless the LWC is confirmed to already handle a
  `"transcribed"` status.

### 5.4 `main.py` — `_process_email` reference docs (secondary fix)

In `_process_email`, the reference-doc loop (around lines ~487–498) currently
does `extractor.extract(...)` and ingests only when `result.method == "Text"`,
logging and skipping the `Vision` case. Update it so a scanned reference doc
is transcribed and ingested instead of skipped:

```python
        for filename, file_bytes in reference_docs:
            try:
                result = extractor.extract(file_bytes, filename)
                if result.method == "Text":
                    rag.ingest(rfp_id, filename, result.text)
                elif filename.lower().endswith(".pdf"):
                    # Scanned reference doc: transcribe pages to text, then
                    # ingest the transcription like any other document.
                    text = extractor.transcribe_scanned_pdf(
                        file_bytes, config.TRANSCRIPTION_MAX_PAGES,
                        config.TRANSCRIPTION_MODEL)
                    if text:
                        rag.ingest(rfp_id, filename, text)
                else:
                    logger.info("Skipping non-PDF vision doc %s", filename)
            except ValueError as e:
                logger.warning("Skipping reference doc %s: %s", filename, e)
```

This keeps the triage (small-doc) vision path untouched — scanned small ITBs
still go through `analyzer.analyze_rfp` for fact extraction as before.

---

## 6. Tests

`test_email_processing.py` mocks `extractor`, `rag`, `storage`, `config`, and
`analyzer` via `_patch_deps()`, and drives the Flask app with
`app.test_client()`. The mocked `config` in `_patch_deps()` is a `Mock` with
only specific attributes set, so add the two new attributes to that mock or
attribute access will return a `Mock` object instead of a value. Update the
`config` mock in `_patch_deps()` to include:

```python
            TRANSCRIPTION_MAX_PAGES=200, TRANSCRIPTION_MODEL="test-vision",
```

### 6.1 Update the existing skip test

`test_ingest_skips_vision_docs` currently asserts a scanned doc is `skipped`
and `rag.ingest` is not called. That behavior changes: a scanned PDF now goes
to transcription. Rewrite it to assert the new path. Because `_run_ingest`
runs in a background thread, keep using the existing `_wait_for_job` helper.

```python
def test_ingest_transcribes_scanned_pdf():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"scan-bytes")
    try:
        with mock.patch("extractor.extract_text_only", return_value=""), \
             mock.patch("extractor.transcribe_scanned_pdf",
                        return_value="Transcribed page text " * 10):
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "scan.pdf",
                "gcsPath": "a3cTEST/scan.pdf"})
        assert r.status_code == 202
        job = _wait_for_job("a3cTEST/scan.pdf", mocks)
        assert job["status"] == "ingested"
        # The transcription (not the raw bytes) is what got ingested.
        assert mocks["rag"].ingest.called
        ingested_text = mocks["rag"].ingest.call_args.args[2]
        assert "Transcribed page text" in ingested_text
    finally:
        mock.patch.stopall()
```

### 6.2 Transcription failure still skips cleanly

```python
def test_ingest_skips_when_transcription_empty():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"scan-bytes")
    try:
        with mock.patch("extractor.extract_text_only", return_value=""), \
             mock.patch("extractor.transcribe_scanned_pdf",
                        side_effect=ValueError("transcription produced no text")):
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "scan.pdf",
                "gcsPath": "a3cTEST/scan.pdf"})
        assert r.status_code == 202
        job = _wait_for_job("a3cTEST/scan.pdf", mocks)
        assert job["status"] == "skipped"
        mocks["rag"].ingest.assert_not_called()
    finally:
        mock.patch.stopall()
```

### 6.3 Text-layer docs unaffected

Add a guard test that a normal text PDF does NOT trigger transcription:

```python
def test_text_pdf_does_not_transcribe():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"pdf")
    long_text = "real text layer " * 20  # > MIN_TEXT_CHARS
    try:
        with mock.patch("extractor.extract_text_only", return_value=long_text), \
             mock.patch("extractor.transcribe_scanned_pdf") as tr:
            _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "spec.pdf",
                "gcsPath": "a3cTEST/spec.pdf"})
            _wait_for_job("a3cTEST/spec.pdf", mocks)
        tr.assert_not_called()
    finally:
        mock.patch.stopall()
```

Run the suite with:

```
cd rfp-triage-service
python -m pytest -q
```

All tests must pass with no network calls (everything external is mocked).

---

## 7. Acceptance Criteria

1. A scanned PDF uploaded through the Deep Dive UI (or received as an email
   reference doc) results in `rag.ingest` being called with transcribed text,
   and the ingest job reaching `ingested`.
2. A text-layer PDF takes the existing fast path and never calls the
   transcription model.
3. A scanned PDF whose transcription yields nothing is marked `skipped` with
   a clear reason; `rag.ingest` is not called.
4. No new entries in `requirements.txt`.
5. `python -m pytest -q` passes.
6. The transcription model defaults to `google/gemini-2.5-flash` and is
   overridable via `TRANSCRIPTION_MODEL`. DeepSeek is never used for
   transcription (text-only).

## 8. Operational Notes for the Human

- **Cost:** transcription is one vision call per page. Gemini 2.5 Flash
  vision is roughly $0.002/page all-in, so a 200-page scanned spec book is
  well under a dollar, once (re-ingestion replaces chunks; it does not
  re-bill unless re-triggered).
- **Timeout:** transcription runs inside the existing background thread in
  `_run_ingest`, so long documents do not hit the 60s Apex callout timeout.
  The LWC already polls `/ingest-status` for up to ~5 minutes. A very large
  scanned document (hundreds of pages at ~1–2s per page) could exceed that
  polling window — if that becomes common, increase the LWC's poll cap
  (`maxAttempts` in `rfpDeepDive.js`) or reduce `TRANSCRIPTION_MAX_PAGES`.
- **Set the env var in Cloud Run** (Secret Manager / env): `TRANSCRIPTION_MODEL`
  and `TRANSCRIPTION_MAX_PAGES` are optional; sane defaults are baked in.

## 9. Suggested Commit Message

```
Transcribe scanned PDFs into the RAG index

Scanned/image-only PDFs were previously skipped during ingestion, so the
Deep Dive assistant couldn't answer questions about them. Render pages and
transcribe them with a cheap vision model (Gemini 2.5 Flash via OpenRouter),
then chunk and embed the transcription like any text document.

Applies to both UI uploads and email reference docs. Text-layer PDFs are
unaffected. Adds TRANSCRIPTION_MODEL and TRANSCRIPTION_MAX_PAGES env vars.
```
