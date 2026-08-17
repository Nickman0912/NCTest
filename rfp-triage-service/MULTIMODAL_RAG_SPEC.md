# Multimodal RAG — Visual Page Retrieval & Inline Drawing Citations — Implementation Spec

> **Audience:** an implementing agent (this was written to be handed to
> Gemini, but any competent agent or developer can execute it).
> Plain text and code only — no images, no diagrams, nothing that requires
> visual rendering.
>
> **Project root:** `C:\Users\NicolasClemens\FuryDev\NCTest\NCTest`
> **Service directory:** `rfp-triage-service/` (Python edits are relative to
> that directory). **Salesforce directory:** `force-app/main/default/`
> (Apex/LWC edits are relative to that directory).

---

## 1. Goal

Today the Deep Dive assistant answers questions from **text only**. Scanned
PDFs are transcribed to text (see `SCANNED_PDF_TRANSCRIPTION_SPEC.md`), but
the page images themselves are discarded. That means the assistant cannot
reason about floor plans, site layouts, equipment schedules rendered as
drawings, symbol counts, clearances, or any spatial/geometric content — and
users get no visual proof of where an answer came from.

This change implements **true multimodal RAG**:

1. **Archive page images at ingest time.** Every PDF page (text-layer and
   scanned) is rendered to a PNG and stored in GCS under a stable path.
2. **Index page images alongside text chunks.** A new `page_images` table
   maps each stored page image to its RFP, source file, and page number, and
   stores a short visual description embedding so image-heavy pages are
   retrievable by meaning.
3. **Retrieve images at question time.** When the top text chunks come from
   pages that have stored images, the relevant page images are fetched and
   passed to the generation model as vision input, so the model can see the
   actual drawing.
4. **Return visual citations.** The `/ask` response includes signed image
   URLs for the pages used, and the LWC renders them as clickable thumbnails
   inline in the chat so the estimator can verify the answer against the
   real blueprint without leaving Salesforce.

After this change:

- A user can ask "Where is the fire riser on the site plan?" and get an
  answer grounded in the actual drawing, with the drawing shown inline.
- A user can ask "How many 4-gang boxes are on the power plan?" and the
  model counts symbols on the rendered page.
- Every visual answer is backed by a clickable page thumbnail in the chat.

## 2. Non-Goals

- Do NOT change the **triage** path (`extract()` / `_analyze_openrouter`).
  Triage stays text/small-vision as-is.
- Do NOT change chunking strategy, embedding model, or the `document_chunks`
  table shape. Text retrieval is untouched; images are an additive layer.
- Do NOT re-render pages for documents that already have a text layer UNLESS
  the page is image-heavy (see 5.2 — we only pay to store/describe pages
  that carry visual information).
- Do NOT add new Python dependencies beyond what is already pinned
  (`pypdfium2`, `Pillow`, `openai`, `google-cloud-storage`, `psycopg`,
  `pgvector`). All are already in `requirements.txt`.
- Do NOT make the LWC depend on GCS directly. The browser only ever sees
  short-lived signed URLs minted by the service; the bucket stays private.

## 3. Critical Model Constraint (read this first)

**The generation model must be vision-capable to see page images.**
`GENERATION_MODEL` currently defaults to `anthropic/claude-sonnet-4.5`,
which IS vision-capable, so no change is required for the default path. If
an operator overrides `GENERATION_MODEL` to a text-only model (e.g.
DeepSeek chat), visual retrieval still works but the model will only use
the text excerpts — the images are simply ignored. That is an acceptable
degradation, not a failure.

The **visual description** model used at ingest time MUST be vision-capable.
Default it to `google/gemini-2.5-flash` (cheap, already used for
transcription). Make it configurable via a new env var
`VISUAL_DESCRIPTION_MODEL`. DeepSeek chat models are text-only and must
never be routed here.

Vision input format (same pattern already used in
`analyzer._analyze_openrouter` and `extractor.transcribe_scanned_pdf`): each
page is a base64 PNG passed as an `image_url` content part with a
`data:image/png;base64,...` URL.

## 4. Files to Modify

### Python service (`rfp-triage-service/`)

1. `config.py` — add `VISUAL_DESCRIPTION_MODEL`, `PAGE_IMAGE_DPI`,
   `PAGE_IMAGE_MAX_PAGES`, `VISUAL_RETRIEVAL_TOP_K`, and a
   `PAGE_IMAGE_SIGNED_URL_MINUTES` TTL.
2. `storage.py` — add `upload_page_image()` and
   `generate_page_image_urls()` (batch signed GET URLs).
3. `extractor.py` — add `render_pages_with_text()` that returns, per page,
   both the rendered PNG (base64) and whether the page is "image-heavy"
   (low text yield relative to page area), so we only store/describe pages
   that carry visual information.
4. `rag.py` — add a `page_images` table to the DDL, an
   `ingest_page_images()` writer, a `retrieve_page_images()` reader, and
   extend `ask()` to fetch relevant page images and pass them to the
   generation model as vision content, returning `image_citations`.
5. `main.py` — in `_run_ingest`, after text ingest, render + store page
   images and index them; add a `/page-image-urls` endpoint (or fold URLs
   into `/ask` — see 5.5) so the LWC can display them.
6. `test_email_processing.py` — add coverage for page-image indexing and
   visual retrieval.

### Salesforce (`force-app/main/default/`)

7. `classes/RFPDeepDiveController.cls` — add an `imageUrl` field to the
   `Citation` class and parse it in `ask()` / `parseCitations()`.
8. `lwc/rfpDeepDive/rfpDeepDive.js` — carry `imageUrl` on citations; add a
   lightbox/modal state for viewing a full-size page image.
9. `lwc/rfpDeepDive/rfpDeepDive.html` — render a thumbnail `<img>` for any
   citation that has an `imageUrl`; clicking opens the full image.
10. `lwc/rfpDeepDive/rfpDeepDive.css` — thumbnail + lightbox styling that
    matches the existing ethereal/aurora theme.

No new Salesforce objects, fields, or metadata are required. The
`RFP_Triage_Config__mdt` record is unchanged.

---

## 5. Detailed Changes

### 5.1 `config.py`

Add near the other model settings (after the `TRANSCRIPTION_MAX_PAGES`
line):

```python
# VISUAL_DESCRIPTION_MODEL: vision model used to write a one-paragraph
#   visual description of image-heavy pages at ingest time. MUST be
#   vision-capable (DeepSeek chat models are text-only and will NOT work).
VISUAL_DESCRIPTION_MODEL = os.environ.get(
    "VISUAL_DESCRIPTION_MODEL", "google/gemini-2.5-flash")
# DPI for archived page images. 150 is legible for drawings and keeps each
# PNG ~300-500KB.
PAGE_IMAGE_DPI = int(os.environ.get("PAGE_IMAGE_DPI", "150"))
# Cap pages archived per document so a runaway plan set can't blow up
# storage or the background thread's runtime.
PAGE_IMAGE_MAX_PAGES = int(os.environ.get("PAGE_IMAGE_MAX_PAGES", "200"))
# How many page images to attach to a single /ask call as vision input.
# Keep small: each image is real tokens and latency.
VISUAL_RETRIEVAL_TOP_K = int(os.environ.get("VISUAL_RETRIEVAL_TOP_K", "3"))
# Signed GET URL lifetime for page images shown in the LWC.
PAGE_IMAGE_SIGNED_URL_MINUTES = int(
    os.environ.get("PAGE_IMAGE_SIGNED_URL_MINUTES", "60"))
```

### 5.2 `extractor.py`

Add a module constant near `TRANSCRIPTION_DPI`:

```python
# A page is "image-heavy" (worth archiving + describing) when its extracted
# text is sparse relative to a full page of text. Below this many characters
# of text-layer content, we treat the page as carrying visual information
# (drawings, plans, schedules rendered as graphics) and archive its image.
IMAGE_HEAVY_TEXT_THRESHOLD = 200
```

Add a renderer that returns per-page PNGs plus an image-heavy flag. Reuse
the existing render pattern; do NOT change `_render_pages` or
`_render_all_pages` (they are shared with triage/transcription):

```python
def render_pages_with_text(file_bytes: bytes, max_pages: int,
                           dpi: int) -> list[dict]:
    """Render up to max_pages PDF pages to base64 PNGs, flagging image-heavy
    pages.

    Returns a list of {"page": int (1-based), "png_b64": str,
    "image_heavy": bool}. A page is image-heavy when its text layer is
    sparse (drawings, plans, schedules as graphics). Raises ValueError if
    the file is not a PDF.
    """
    import io
    import base64
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(file_bytes)
    out = []
    total = len(pdf)
    for i in range(min(total, max_pages)):
        page = pdf[i]
        text = (page.get_textpage().get_text_range() or "").strip()
        bitmap = page.render(scale=dpi / 72)
        img = bitmap.to_pil()
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        out.append({
            "page": i + 1,
            "png_b64": base64.b64encode(buf.getvalue()).decode(),
            "image_heavy": len(text) < IMAGE_HEAVY_TEXT_THRESHOLD,
        })
    if total > max_pages:
        logger.warning("PDF has %d pages; only first %d archived as images",
                       total, max_pages)
    pdf.close()
    return out
```

### 5.3 `storage.py`

Add two functions. Page images live under
`{rfp_id}/pages/{source_file}/page_{NNN}.png` so they are namespaced per
document and never collide with the raw upload at `{rfp_id}/{filename}`.

```python
def upload_page_image(rfp_id: str, source_file: str, page: int,
                      png_bytes: bytes) -> str:
    """Upload one rendered page PNG to GCS. Returns the gs:// URI."""
    bucket = _bucket()
    safe = source_file.replace("/", "_")
    path = f"{rfp_id}/pages/{safe}/page_{page:03d}.png"
    blob = bucket.blob(path)
    blob.upload_from_string(png_bytes, content_type="image/png")
    return f"gs://{config.GCS_BUCKET}/{path}"


def generate_page_image_urls(gcs_paths: list[str],
                             ttl_minutes: int) -> dict:
    """Mint V4 signed GET URLs for a list of gs:// page-image URIs.

    Returns {gs_uri: signed_url}. Uses the same IAM Credentials signBlob
    pattern as generate_upload_url (Cloud Run has no private key)."""
    import datetime
    import google.auth
    from google.auth.transport import requests as auth_requests

    credentials, _ = google.auth.default()
    credentials.refresh(auth_requests.Request())
    bucket = _bucket()
    urls = {}
    for uri in gcs_paths:
        # uri is gs://bucket/path -> strip the scheme + bucket to get path
        path = uri.split(f"gs://{config.GCS_BUCKET}/", 1)[-1]
        blob = bucket.blob(path)
        urls[uri] = blob.generate_signed_url(
            version="v4",
            expiration=datetime.timedelta(minutes=ttl_minutes),
            method="GET",
            service_account_email=credentials.service_account_email,
            access_token=credentials.token,
        )
    return urls
```

### 5.4 `rag.py`

**DDL** — add a `page_images` table (append to the existing `DDL` string,
keeping the existing tables intact):

```sql
CREATE TABLE IF NOT EXISTS page_images (
    id UUID PRIMARY KEY,
    rfp_id TEXT NOT NULL,
    source_file TEXT NOT NULL,
    page INT NOT NULL,
    gcs_uri TEXT NOT NULL,
    visual_description TEXT,
    embedding vector(1536)
);
CREATE INDEX IF NOT EXISTS idx_page_images_rfp ON page_images (rfp_id);
```

**Writer** — store page images and embed their visual descriptions:

```python
def ingest_page_images(rfp_id: str, source_file: str,
                       pages: list[dict]) -> int:
    """Store page images for a document and embed a visual description of
    each image-heavy page. `pages` is the list from
    extractor.render_pages_with_text(). Returns the number of pages stored.

    Only image-heavy pages get a visual description + embedding (text pages
    are already fully covered by document_chunks). All pages are archived to
    GCS so any page can be shown as a visual citation later.
    """
    import storage
    stored = 0
    rows = []
    for p in pages:
        png = base64.b64decode(p["png_b64"])
        gcs_uri = storage.upload_page_image(rfp_id, source_file, p["page"], png)
        desc = ""
        if p["image_heavy"]:
            desc = _describe_page_image(p["png_b64"])
        rows.append((str(uuid.uuid4()), rfp_id, source_file, p["page"],
                     gcs_uri, desc))
        stored += 1

    # Embed only the non-empty descriptions, in batch.
    descs = [r[5] for r in rows if r[5]]
    embs = _embed(descs) if descs else []
    emb_iter = iter(embs)

    with _connect() as conn:
        conn.execute(
            "DELETE FROM page_images WHERE rfp_id = %s AND source_file = %s",
            (rfp_id, source_file))
        for r in rows:
            emb = next(emb_iter) if r[5] else None
            conn.execute(
                "INSERT INTO page_images (id, rfp_id, source_file, page, "
                "gcs_uri, visual_description, embedding) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s)",
                (r[0], r[1], r[2], r[3], r[4], r[5], emb))
    logger.info("Archived %d page images for %s/%s", stored, rfp_id,
                source_file)
    return stored
```

**Visual description helper** (module-level, uses the description model):

```python
DESCRIBE_PROMPT = (
    "Describe this document page in one concise paragraph for search. "
    "Capture: the sheet/page title or number if visible, the type of drawing "
    "(floor plan, site plan, schedule, elevation, detail, schematic), the "
    "rooms/areas/equipment shown, and any dimensions, counts, or callouts. "
    "Plain text only, no markdown."
)


def _describe_page_image(png_b64: str) -> str:
    from openai import OpenAI
    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)
    try:
        resp = client.chat.completions.create(
            model=config.VISUAL_DESCRIPTION_MODEL,
            max_tokens=300,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": DESCRIBE_PROMPT},
                    {"type": "image_url",
                     "image_url": {"url": f"data:image/png;base64,{png_b64}"}},
                ],
            }],
        )
        return (resp.choices[0].message.content or "").strip()
    except Exception:
        logger.exception("Visual description failed for a page")
        return ""
```

**Reader** — retrieve the most relevant page images for a question:

```python
def retrieve_page_images(rfp_id: str, question: str,
                         top_k: int) -> list[dict]:
    """Return up to top_k page images most relevant to the question, ranked
    by visual-description embedding similarity. Only image-heavy pages have
    embeddings, so text-only pages are naturally excluded."""
    question_emb = _embed([question])[0]
    with _connect() as conn:
        rows = conn.execute(
            "SELECT source_file, page, gcs_uri, visual_description "
            "FROM page_images WHERE rfp_id = %s AND embedding IS NOT NULL "
            "ORDER BY embedding <=> %s::vector LIMIT %s",
            (rfp_id, str(question_emb), top_k)).fetchall()
    return [{"file": r[0], "page": r[1], "gcs_uri": r[2],
             "description": r[3]} for r in rows]
```

**Extend `ask()`** — after the existing text-chunk retrieval, also retrieve
page images, attach them as vision content, and return them as citations.
Keep the text path identical; images are additive. Replace the body of
`ask()` from the `client = OpenAI(...)` line down with:

```python
    # Visual retrieval: pull the most relevant drawing/plan pages and let
    # the model see them. Best-effort: if it fails, fall back to text-only.
    image_hits = []
    try:
        image_hits = retrieve_page_images(
            rfp_id, question, config.VISUAL_RETRIEVAL_TOP_K)
    except Exception:
        logger.exception("Page-image retrieval failed; answering text-only")

    content = [{
        "type": "text",
        "text": (
            "You are helping a construction estimator review bid documents. "
            "Answer the question using ONLY the excerpts and page images "
            "below. If the answer isn't in them, say so plainly - do not "
            "guess. Cite which excerpt or page each fact came from (reference "
            "pages as 'filename page N').\n\n"
            f"EXCERPTS:\n{context}\n\nQUESTION: {question}"
        ),
    }]
    for hit in image_hits:
        content.append({
            "type": "text",
            "text": f"PAGE IMAGE: {hit['file']} page {hit['page']}",
        })
        content.append({
            "type": "image_url",
            "image_url": {"url": _gcs_uri_to_data_url(hit["gcs_uri"])},
        })

    from openai import OpenAI
    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)
    resp = client.chat.completions.create(
        model=config.GENERATION_MODEL,
        max_tokens=1000,
        messages=[{"role": "user", "content": content}],
    )

    # Mint signed URLs so the LWC can render the cited pages as thumbnails.
    image_citations = []
    if image_hits:
        try:
            import storage
            url_map = storage.generate_page_image_urls(
                [h["gcs_uri"] for h in image_hits],
                config.PAGE_IMAGE_SIGNED_URL_MINUTES)
            image_citations = [
                {"file": h["file"], "page": h["page"],
                 "imageUrl": url_map.get(h["gcs_uri"], "")}
                for h in image_hits
            ]
        except Exception:
            logger.exception("Could not mint page-image URLs")

    return {
        "answer": resp.choices[0].message.content,
        "citations": [{"file": r[0], "chunk": r[1], "excerpt": r[2]}
                      for r in rows],
        "image_citations": image_citations,
    }
```

Add the small helper that turns a `gs://` URI into a base64 data URL for the
vision call (the model cannot fetch GCS itself):

```python
def _gcs_uri_to_data_url(gcs_uri: str) -> str:
    """Download a page image and return a data: URL for vision input."""
    import storage
    path = gcs_uri.split(f"gs://{config.GCS_BUCKET}/", 1)[-1]
    png = storage.download_blob(path)
    return "data:image/png;base64," + base64.b64encode(png).decode()
```

Add `import base64` to the top of `rag.py` if not already present.

### 5.5 `main.py` — `_run_ingest`

After the existing `chunks = rag.ingest(...)` success path (and after the
`transcribed` branch sets its status), archive + index page images. This is
best-effort: a page-image failure must NOT fail the whole ingest. Insert
this block right before the final `rag.set_job(... "ingested" ...)` calls,
inside the same `try`:

```python
        # Archive page images + index visual descriptions (multimodal RAG).
        # Best-effort: never let image archiving fail the text ingest.
        if filename.lower().endswith(".pdf") and config.GCS_BUCKET:
            try:
                pages = extractor.render_pages_with_text(
                    file_bytes, config.PAGE_IMAGE_MAX_PAGES,
                    config.PAGE_IMAGE_DPI)
                rag.ingest_page_images(rfp_id, filename, pages)
            except Exception:
                logger.exception("Page-image archiving failed for %s",
                                 filename)
```

Note: `file_bytes` is already in scope in `_run_ingest` (downloaded at the
top). No new download is needed.

Do the same in `_process_email` for reference docs: after the
`rag.ingest(rfp_id, filename, ...)` calls in the reference-doc loop, add the
same guarded `render_pages_with_text` + `ingest_page_images` block (the
`file_bytes` for each reference doc is already in scope there).

### 5.6 `RFPDeepDiveController.cls`

Add an `imageUrl` field to the `Citation` class:

```apex
public class Citation {
    @AuraEnabled public String file;
    @AuraEnabled public Integer chunk;
    @AuraEnabled public String excerpt;
    @AuraEnabled public String imageUrl;   // signed GCS URL for visual pages
    @AuraEnabled public Integer page;      // page number for visual citations
}
```

In `parseCitations()`, also parse `imageUrl` and `page` (both may be null
for text-only citations):

```apex
cit.imageUrl = (String) cm.get('imageUrl');
Object pg = cm.get('page');
cit.page = pg == null ? null : Integer.valueOf(String.valueOf(pg));
```

In `ask()`, after parsing text `citations`, also parse the new
`image_citations` array from the response and merge it into
`resp.citations` (visual citations have `page` + `imageUrl` but no `chunk`/
`excerpt`). The simplest correct approach: deserialize `image_citations`
into `Citation` objects (setting `file`, `page`, `imageUrl`) and
`resp.citations.addAll(...)` them after the text citations. The LWC
distinguishes them by `imageUrl != null`.

### 5.7 `rfpDeepDive.js`

In `_pushMessage()`, carry the new fields on each citation and flag visual
ones:

```javascript
const cits = (citations || []).map((c, i) => ({
  key: `${msgId}-${i}`,
  file: c.file,
  chunk: c.chunk,
  excerpt: c.excerpt,
  imageUrl: c.imageUrl || null,
  page: c.page || null,
  isVisual: !!c.imageUrl
}));
```

Add lightbox state and handlers:

```javascript
@track lightboxUrl = null;
@track lightboxLabel = "";

get showLightbox() {
  return !!this.lightboxUrl;
}

handleOpenImage(event) {
  this.lightboxUrl = event.currentTarget.dataset.url;
  this.lightboxLabel = event.currentTarget.dataset.label;
}

handleCloseLightbox() {
  this.lightboxUrl = null;
  this.lightboxLabel = "";
}
```

### 5.8 `rfpDeepDive.html`

Inside the existing citations loop, render a thumbnail when the citation is
visual. Replace the inner `citation` div content with a conditional: visual
citations show an `<img>` thumbnail + a "filename — page N" label; text
citations keep the existing excerpt markup.

```html
<template for:each={msg.citations} for:item="cit">
  <div key={cit.key} class="citation">
    <template if:true={cit.isVisual}>
      <button
        class="cite-thumb-btn"
        data-url={cit.imageUrl}
        data-label={cit.file}
        onclick={handleOpenImage}
      >
        <img src={cit.imageUrl} alt={cit.file} class="cite-thumb" />
        <span class="citation-file">{cit.file} &mdash; page {cit.page}</span>
      </button>
    </template>
    <template if:false={cit.isVisual}>
      <span class="citation-file">{cit.file} &mdash; section {cit.chunk}</span>
      <span class="citation-excerpt">{cit.excerpt}</span>
    </template>
  </div>
</template>
```

Add a lightbox overlay at the end of the card (before `</article>`):

```html
<template if:true={showLightbox}>
  <div class="lightbox-backdrop" onclick={handleCloseLightbox}>
    <div class="lightbox-panel" onclick={handleCloseLightbox}>
      <img src={lightboxUrl} alt={lightboxLabel} class="lightbox-img" />
      <p class="lightbox-caption">{lightboxLabel}</p>
    </div>
  </div>
</template>
```

### 5.9 `rfpDeepDive.css`

Add styles consistent with the existing aurora/ethereal theme (glassy,
soft borders, accent glow). Append:

```css
.cite-thumb-btn {
  display: flex;
  flex-direction: column;
  gap: 6px;
  background: none;
  border: none;
  padding: 0;
  cursor: zoom-in;
  text-align: left;
}
.cite-thumb {
  width: 180px;
  max-width: 100%;
  border-radius: 10px;
  border: 1px solid rgba(255, 255, 255, 0.18);
  box-shadow: 0 4px 18px rgba(0, 0, 0, 0.25);
  transition: transform 0.15s ease, box-shadow 0.15s ease;
}
.cite-thumb-btn:hover .cite-thumb {
  transform: translateY(-2px);
  box-shadow: 0 8px 26px rgba(0, 0, 0, 0.35);
}
.lightbox-backdrop {
  position: fixed;
  inset: 0;
  background: rgba(8, 10, 20, 0.78);
  backdrop-filter: blur(6px);
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 9999;
}
.lightbox-panel {
  max-width: 90vw;
  max-height: 90vh;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 10px;
  cursor: zoom-out;
}
.lightbox-img {
  max-width: 90vw;
  max-height: 82vh;
  border-radius: 12px;
  box-shadow: 0 20px 60px rgba(0, 0, 0, 0.5);
}
.lightbox-caption {
  color: #e8ecf5;
  font-size: 0.85rem;
  opacity: 0.85;
}
```

---

## 6. Tests

Add to `test_email_processing.py` (follow the existing mock patterns).

### 6.1 Page images are archived + indexed on ingest

```python
def test_ingest_archives_page_images():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"pdf-bytes")
    try:
        with mock.patch("extractor.extract_text_only",
                        return_value="Some text " * 50), \
             mock.patch("extractor.render_pages_with_text",
                        return_value=[{"page": 1, "png_b64": "AAAA",
                                       "image_heavy": True}]), \
             mock.patch("rag.ingest", return_value=5), \
             mock.patch("rag.ingest_page_images", return_value=1) as pimgs:
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "plans.pdf",
                "gcsPath": "a3cTEST/plans.pdf"})
            assert r.status_code == 202
            pimgs.assert_called_once()
    finally:
        _unpatch(mocks)
```

### 6.2 Page-image failure does not fail the ingest

```python
def test_ingest_survives_page_image_failure():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"pdf-bytes")
    try:
        with mock.patch("extractor.extract_text_only",
                        return_value="Some text " * 50), \
             mock.patch("extractor.render_pages_with_text",
                        side_effect=RuntimeError("render boom")), \
             mock.patch("rag.ingest", return_value=5):
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "plans.pdf",
                "gcsPath": "a3cTEST/plans.pdf"})
            assert r.status_code == 202  # ingest still accepted
    finally:
        _unpatch(mocks)
```

### 6.3 `ask()` attaches page images and returns image citations

Mock `rag.retrieve_page_images` to return one hit, mock
`storage.generate_page_image_urls` to return a signed URL, mock the OpenAI
client, and assert the response JSON contains `image_citations` with the
signed URL and that the vision message included an `image_url` part.

## 7. Acceptance Criteria

1. Ingesting a PDF archives every page (up to `PAGE_IMAGE_MAX_PAGES`) to GCS
   under `{rfp_id}/pages/{file}/page_NNN.png` and inserts rows into
   `page_images`.
2. Image-heavy pages get a non-empty `visual_description` and an embedding;
   text-heavy pages are archived but not described/embedded.
3. `ask()` returns both `citations` (text) and `image_citations` (with
   signed `imageUrl`s) when relevant drawings exist.
4. The generation model receives page images as vision input on relevant
   questions.
5. A page-image archiving or retrieval failure never breaks text ingest or
   text-only answering.
6. The LWC renders visual citations as thumbnails and opens a full-size
   lightbox on click; text citations render exactly as before.
7. No new entries in `requirements.txt`.
8. `python -m pytest -q` passes; Apex tests for
   `RFPDeepDiveController` pass.
9. `VISUAL_DESCRIPTION_MODEL` defaults to `google/gemini-2.5-flash` and is
   overridable; DeepSeek is never used for visual description (text-only).

## 8. Operational Notes for the Human

- **Storage cost:** ~300–500KB per page PNG. 100k pages ≈ 40GB ≈
  **$0.80/month** in `us-central1` Standard storage. Set a lifecycle rule to
  move `pages/` objects older than 90 days to Nearline ($0.010/GB) if
  volume grows.
- **Ingest cost:** one visual-description call per image-heavy page
  (~$0.002). A 200-page plan set with 60 drawing pages ≈ **$0.12** once.
- **Query cost:** up to `VISUAL_RETRIEVAL_TOP_K` (default 3) page images per
  question. Each image is roughly 1–2k tokens of vision input; at Sonnet
  4.5 pricing that is well under **$0.01 per visual question**.
- **Latency:** image retrieval adds one embedding + one vector query
  (~50ms) plus image download (~100–300ms for up to 3 PNGs). Acceptable
  inside the existing 60s Apex timeout.
- **Signed URL TTL:** `PAGE_IMAGE_SIGNED_URL_MINUTES` defaults to 60. The
  LWC shows thumbnails immediately after `ask()` returns, so 60 minutes is
  generous; a user who leaves the tab open for hours may need to re-ask to
  refresh expired thumbnails.
- **Env vars:** all new settings have sane defaults baked in; nothing new is
  required in Secret Manager to deploy. Override via Cloud Run env vars only
  if tuning is needed.
- **Backfill:** existing ingested documents have no page images. They
  continue to work text-only. To backfill, re-upload (re-ingest replaces
  chunks and now also archives pages) or run a one-off script that calls
  `render_pages_with_text` + `ingest_page_images` for each GCS reference doc.

## 9. Suggested Commit Message

```
Add multimodal RAG: visual page retrieval + inline drawing citations

Archive every PDF page to GCS at ingest, index a visual description
embedding for image-heavy pages, and retrieve relevant page images at
question time so the generation model can see actual drawings. /ask now
returns signed image URLs; the Deep Dive LWC renders them as clickable
thumbnails with a lightbox, giving estimators visual proof inline.

Text retrieval is unchanged; images are an additive, best-effort layer.
Adds VISUAL_DESCRIPTION_MODEL, PAGE_IMAGE_DPI, PAGE_IMAGE_MAX_PAGES,
VISUAL_RETRIEVAL_TOP_K, and PAGE_IMAGE_SIGNED_URL_MINUTES env vars.
```
