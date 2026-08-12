# Plan: Email-Body-Aware Triage & Attachment Classification

## Context

The RFP triage service lives in `rfp-triage-service/` (Flask app on Cloud Run).
Current behavior: `/poll` and `/webhook/email` iterate over **attachments only**,
creating one `RFP__c` Salesforce record per attachment. The email body is
ignored, and every attachment — whether a 1-page ITB letter or a 200-page spec
book — is sent to the triage LLM.

**Goal:** Treat each email as one unit. Combine body + small attachments into a
single triage analysis producing ONE Salesforce record. Route large reference
documents to GCS + vector DB ingestion (for the existing `/ask` deep-dive
endpoint) without sending them to the triage LLM.

## Files to modify

- `rfp-triage-service/main.py` — restructure `_process_document` flow into
  per-email processing
- `rfp-triage-service/extractor.py` — add page-count helper
- `rfp-triage-service/config.py` — new env vars
- `rfp-triage-service/storage.py` — NEW: GCS upload helper
- `rfp-triage-service/gmail_client.py` / `graph_client.py` — return email body
  text in addition to metadata
- `rfp-triage-service/requirements.txt` — add `google-cloud-storage`
- `rfp-triage-service/test_email_processing.py` — NEW: tests

## Step 1: Config additions (`config.py`)

```python
# Attachment classification thresholds
TRIAGE_MAX_PAGES = int(os.environ.get("TRIAGE_MAX_PAGES", "30"))
TRIAGE_MAX_TEXT_CHARS = int(os.environ.get("TRIAGE_MAX_TEXT_CHARS", "60000"))
# GCS bucket for reference documents (spec books, plan sets)
GCS_BUCKET = os.environ.get("GCS_BUCKET", "")
```

## Step 2: Page-count helper (`extractor.py`)

Add a lightweight function that returns page count without extracting text:

```python
def pdf_page_count(file_bytes: bytes) -> int:
    from pypdf import PdfReader
    return len(PdfReader(io.BytesIO(file_bytes)).pages)
```

## Step 3: Attachment classification (`main.py`)

New function:

```python
def classify_attachment(filename, file_bytes):
    """Returns 'triage' (read by triage LLM) or 'reference' (GCS + vector DB only)."""
    if filename.lower().endswith('.pdf'):
        try:
            if extractor.pdf_page_count(file_bytes) > config.TRIAGE_MAX_PAGES:
                return 'reference'
        except Exception:
            return 'reference'  # unreadable PDFs shouldn't block triage
    if len(file_bytes) > 2_000_000:  # >2MB non-PDF
        return 'reference'
    return 'triage'
```

## Step 4: Restructure email processing (`main.py`)

Replace the per-attachment loop in both `/webhook/email` and `/poll` with a
per-email function:

```python
def _process_email(subject, body_text, sender, attachments):
    # 1. Split attachments by classification
    triage_docs, reference_docs = [], []
    for filename, file_bytes in attachments:
        (triage_docs if classify_attachment(filename, file_bytes) == 'triage'
         else reference_docs).append((filename, file_bytes))

    # 2. Build combined triage text: email body + small attachment text
    combined = f"Subject: {subject}\n\n{body_text}\n"
    extracted_texts = {}  # saved for RAG ingestion later
    for filename, file_bytes in triage_docs:
        try:
            result = extractor.extract(file_bytes, filename)
            if result.method == "Text":
                extracted_texts[filename] = result.text
                combined += f"\n\n--- ATTACHMENT: {filename} ---\n{result.text}"
            # Vision-path small docs: see note below
        except ValueError as e:
            logger.warning("Skipping %s: %s", filename, e)

    combined = combined[:config.TRIAGE_MAX_TEXT_CHARS]

    # 3. ONE LLM analysis + scoring on the combined text
    facts = analyzer.analyze_rfp(ExtractionResult(method="Text", text=combined))
    scoring = analyzer.score_rfp(facts)

    # 4. Create ONE Salesforce record (existing payload logic).
    #    Attach the FIRST available attachment as the source document
    #    (or none if body-only).

    # 5. RAG ingestion (best-effort, after record exists):
    #    - extracted_texts from triage docs
    #    - reference docs: extract text (text path only; skip vision for v1),
    #      call rag.ingest(rfp_id, filename, text)
    #    - reference docs ALSO uploaded to GCS if config.GCS_BUCKET set,
    #      under {rfp_id}/{filename}
```

Key behavioral rules:

- **Body-only email** (no attachments): works — combined text is just the body.
- **Vision-path small attachments** (scanned ITB letters): keep existing vision
  flow — send that doc's page images to the vision model separately, and append
  the resulting `summary` text into `combined`. Simplest acceptable v1: process
  vision docs as their own analysis and merge their `summary` into the combined
  text before the main triage call.
- **Reference docs**: never sent to the triage LLM. Extract text via
  `extractor.extract()` (text path only; skip vision for v1), call
  `rag.ingest(rfp_id, filename, text)`, upload raw bytes to the GCS bucket
  under `{rfp_id}/{filename}`.
- **Salesforce record**: exactly one per email. `Source_Email__c` = sender.
  Attach the first available attachment as the ContentVersion (existing logic).

## Step 5: Return email body from mail clients

`gmail_client.fetch_unread_with_attachments()` and the `graph_client`
equivalent must also return the email **body text**:

- **Gmail**: change `format="metadata"` to `format="full"` and extract the
  plain-text body from payload parts (prefer `text/plain`; strip HTML if only
  `text/html` is present). Body parts may be nested — walk `parts`
  recursively, and base64url-decode `body.data`.
- **Graph**: add `body` to the `$select` list, use `body.content`, strip HTML
  (Graph returns HTML by default; `body.contentType` tells you).

Pass `subject` and `body` into `_process_email`.

## Step 6: GCS upload helper (new module `storage.py`)

```python
def upload_reference_doc(rfp_id, filename, file_bytes):
    from google.cloud import storage
    client = storage.Client()
    bucket = client.bucket(config.GCS_BUCKET)
    blob = bucket.blob(f"{rfp_id}/{filename}")
    blob.upload_from_string(file_bytes)
    return f"gs://{config.GCS_BUCKET}/{rfp_id}/{filename}"
```

Add `google-cloud-storage` to `requirements.txt`.

**Deploy note (not code):** grant the Cloud Run runtime service account
`roles/storage.objectAdmin` on bucket `rfp-documents-poc`, and set
`GCS_BUCKET=rfp-documents-poc` on the Cloud Run service.

## Step 7: Tests (`test_email_processing.py`)

- `classify_attachment`: small PDF → triage; 50-page PDF → reference;
  5MB docx → reference; unreadable PDF → reference.
- `_process_email` body-only (mock `analyzer`, `salesforce_client`, `rag`):
  one SF record created; combined text includes subject + body.
- `_process_email` mixed attachments: small doc text included in combined;
  large doc routed to `rag.ingest` + GCS, NOT included in combined text.
- Verify exactly one `salesforce_client.create_rfp_record` call per email
  regardless of attachment count.

## Acceptance criteria

1. BuildingConnected-style body-only ITB email → one RFP record with extracted
   fields.
2. Email with letter PDF + 200-page spec book → one record; spec book queryable
   via `/ask` with the new record's ID; spec book present in GCS.
3. Email with 3 attachments → exactly one Salesforce record.
4. All existing tests still pass (`pytest`).

## Out of scope (do NOT build)

- Downloading documents from BuildingConnected links (requires auth; Phase 2).
- Vision extraction for reference docs (scanned spec books) — log + skip for v1.
- Gating RAG ingestion on Pursue/Review recommendation.
- Any Salesforce-side changes (the LWC + Apex controller already work against
  `/ask` and need no modification).
