# RFP Triage & Deep Dive — Build Documentation

> **Purpose:** Technical and practical documentation of the ITB/RFP ingestion,
> triage, and deep-dive Q&A system built in this project. Covers the
> architecture, how each piece works, how it behaves at scale, and known
> limitations with planned build-out items.
>
> **Last updated:** 2026-08-12

---

## 1. What This System Does (Practical View)

An estimator's mailbox receives Invitations to Bid (ITBs) — usually an email
with attached documents. This system:

1. **Ingests** the email automatically (mailbox polling or webhook forward).
2. **Extracts** the key facts from the ITB (due date, estimated value, scope,
   issuing organization, etc.) using an LLM.
3. **Scores** the opportunity with deterministic Python rules (not the LLM) so
   the same ITB always gets the same score.
4. **Creates an `RFP__c` record in Salesforce** with the facts, score, and
   pursue/review/decline recommendation.
5. **Indexes the bid documents into a vector database** so estimators can ask
   natural-language questions ("What are the liquidated damages?") from the
   RFP record page and get cited answers.
6. Optionally **generates a full project summary** with a recommendation on
   demand.

The user-facing surface is the **RFP Deep Dive** Lightning Web Component on
the `RFP__c` record page: document upload, indexed-document list, suggested
questions, chat thread with source citations, and a generate-summary button.

---

## 2. Architecture Overview

```
┌─────────────┐   poll / webhook   ┌──────────────────────────────────┐
│  Mailbox     │ ────────────────▶ │  rfp-triage-service (Cloud Run)  │
│ (Gmail/M365) │                   │  Flask app, containerized        │
└─────────────┘                   │                                  │
                                  │  extractor ─▶ analyzer ─▶ scorer │
                                  │      │            │              │
                                  │      ▼            ▼              │
                                  │  OpenRouter (LLMs, per-task)     │
                                  │      │                           │
                                  │      ▼                           │
                                  │  rag.py ─▶ Cloud SQL (pgvector)  │
                                  │      │                           │
                                  │      ▼                           │
                                  │  storage.py ─▶ GCS bucket        │
                                  └───────┬──────────────────────────┘
                                          │ REST (JWT bearer OAuth)
                                          ▼
                              ┌────────────────────────┐
                              │  Salesforce            │
                              │  RFP__c records        │
                              │  RFPDeepDiveController │
                              │  rfpDeepDive LWC       │
                              └────────────────────────┘
```

### Components

| Component | Location | Role |
|---|---|---|
| Triage service | `rfp-triage-service/` (Python/Flask on Cloud Run) | Email processing, extraction, scoring, RAG, storage |
| Apex controller | `force-app/main/default/classes/RFPDeepDiveController.cls` | Proxies LWC requests to Cloud Run |
| Deep Dive LWC | `force-app/main/default/lwc/rfpDeepDive/` | Estimator-facing chat UI on RFP records |
| Vector store | Cloud SQL Postgres + pgvector | Chunked document embeddings, per-RFP isolation |
| Blob store | Google Cloud Storage bucket | Raw reference documents and UI uploads |
| LLM gateway | OpenRouter | Single API for embeddings + chat models |

---

## 3. The Two Document Paths (Critical Distinction)

The system has **two separate flows** that touch documents. Understanding the
difference matters — they have different capabilities and limits.

### 3.1 Triage path (one-time analysis)

`_process_email()` in `main.py`:

1. Attachments are classified (`classify_attachment`) as **triage** (small,
   likely the ITB itself) or **reference** (large spec books / plan sets).
   Thresholds: `TRIAGE_MAX_PAGES` (30) and `TRIAGE_MAX_TEXT_CHARS` (60000).
2. Triage docs get text extracted (`extractor.extract`). Email body + triage
   text are combined into one analysis payload.
3. **Scanned triage docs take the vision path**: pages are rendered to PNG
   (150 DPI, capped at `MAX_VISION_PAGES = 15`) and sent to
   `VISION_MODEL` (`openai/gpt-4o-mini`). Only the resulting **summary** is
   merged into the combined text.
4. One LLM call (`EXTRACTION_MODEL`, `google/gemini-2.5-flash`) extracts
   structured facts against a strict JSON schema (`EXTRACTION_SCHEMA` in
   `analyzer.py`). Structured output is enforced via `json_schema`
   response_format (OpenRouter) or tool-use (Anthropic fallback path).
5. `score_rfp()` computes the pursuit score **deterministically** — value
   threshold, response window, capability overlap vs `COMPANY_CAPABILITIES`,
   incumbent penalty, expired-deadline auto-decline. The LLM never decides
   the score.
6. `extraction_confidence` is capped by a deterministic floor
   (`_confidence_floor`) so a model can't claim high confidence while
   returning nulls for key fields.
7. One `RFP__c` record is created via `salesforce_client.create_rfp_record`.
   The original attachment is stored on the record (base64, skipped if
   > ~4.5 MB).

### 3.2 RAG path (ongoing deep-dive Q&A)

`rag.py` + `_run_ingest()` in `main.py`:

1. **Sources:** small triage attachment text (from emails), reference docs
   from emails, and files uploaded directly in the Deep Dive UI.
2. UI uploads go **direct-to-GCS** via a signed URL (`/upload-url`), then the
   LWC calls `/ingest-document`, which kicks off a **background thread**
   (large spec books exceed the 60s Apex callout timeout). The LWC polls
   `/ingest-status` every 5s (max ~5 min). Job state lives in the
   `ingest_jobs` Postgres table so it survives Cloud Run instance recycling.
3. Ingestion is **text-only** (`extract_text_only`) — see §6, Limitation 1.
4. Text is chunked on paragraph boundaries (`CHUNK_SIZE` 1200 chars,
   `CHUNK_OVERLAP` 200), embedded via `openai/text-embedding-3-small`
   (1536 dims, batched 50/request), and stored in `document_chunks` keyed by
   `rfp_id` + `source_file`. Re-ingesting a file replaces its chunks
   (idempotent).
5. **Query (`ask()`):** the question is embedded; the top 6 nearest chunks
   for that `rfp_id` are retrieved by cosine distance (`<=>`); only those
   chunks + the question go to `GENERATION_MODEL`
   (`anthropic/claude-sonnet-4.5`) with strict instructions to answer only
   from the excerpts and cite sources. The answer + full-chunk citations go
   back to the LWC.
6. **Summarize (`get_context()` + `summarize_rfp()`):** unlike `ask()`, this
   **evenly samples** up to 40 chunks across each source file (not
   similarity-ranked) so the summary covers the whole document end-to-end,
   then generates a structured narrative (overview, dates, scope, commercial
   terms, risks, recommendation).

**Key fact:** the email *body* is NOT ingested into the vector DB — only
document files are. The body lives on the Salesforce record
(`Source_Email__c`) but the assistant cannot answer questions about it.

---

## 4. Model Routing (Cost/Quality Tuning)

All LLM calls go through **OpenRouter** (OpenAI-compatible API), so models
are swappable via environment variables with **no code changes**:

| Env var | Default | Used for |
|---|---|---|
| `EXTRACTION_MODEL` | `google/gemini-2.5-flash` | High-volume structured fact extraction |
| `GENERATION_MODEL` | `anthropic/claude-sonnet-4.5` | User-facing Q&A answers + summaries |
| `VISION_MODEL` | `openai/gpt-4o-mini` | Scanned ITB pages (triage path only) |
| *(hardcoded)* | `openai/text-embedding-3-small` | RAG embeddings |

Rationale: cheap models for high-volume mechanical work; a stronger model
only where estimators see the output. Anthropic direct API is supported as an
alternative provider (`LLM_PROVIDER=anthropic`).

**Cost posture:** because inputs are public ITBs (no company/client data),
cheap open models (DeepSeek, Kimi, etc.) are viable candidates for the
generation tier if cost pressure appears. No such swap has been evaluated
yet — treat as an experiment, not a given.

---

## 5. How It Works at Scale

### Throughput model

- **Email triage** is event-driven and low-volume (ITBs arrive a few at a
  time). One email = one extraction call (≤ ~100k chars in, ~2k tokens out)
  plus a vision call only for scanned triage docs. Cost per ITB is cents.
- **RAG ingestion** is the heavy path: a 300-page spec book is thousands of
  chunks. Embedding cost is dominated by `text-embedding-3-small` pricing
  (fractions of a cent per 1k tokens) — a large document set costs well
  under a dollar to index, once.
- **Q&A** sends only `TOP_K = 6` chunks (~7k chars) per question regardless
  of corpus size, so per-question cost and latency stay flat as document
  volume grows. This is the core scaling property of the design.

### Concurrency & reliability

- Cloud Run scales horizontally; ingestion runs in background threads with
  Postgres-backed job tracking, so instance recycling doesn't lose state.
- The vector DB is plain Postgres + pgvector — no separate vector service to
  operate. Per-RFP row filtering (`WHERE rfp_id = ...`) keeps queries
  scoped and fast; the `idx_chunks_rfp` index supports that. For very large
  corpora, add an ANN index (e.g. HNSW) on the embedding column — not needed
  at current volume since per-RFP chunk counts are small (hundreds to low
  thousands), making the filtered scan cheap.
- Failure modes are graceful: RAG ingestion is best-effort after record
  creation (a failed ingest doesn't block triage); upload polling surfaces
  `skipped`/`error` states to the user with reasons.

### Salesforce-side scaling

- Apex callouts are proxied through `RFPDeepDiveController`; the 60s timeout
  is the reason ingestion is async (signed-URL direct-to-GCS upload +
  polling). Bulk email bursts are handled by the mailbox poller iterating
  messages, one triage unit each.

---

## 6. Known Limitations

### 6.1 Scanned/image-only PDFs — RESOLVED ✅

**Status:** Resolved. Scanned PDFs are now transcribed and indexed for the
Deep Dive assistant (implemented per
`rfp-triage-service/SCANNED_PDF_TRANSCRIPTION_SPEC.md`).

**How it works now:** when `_run_ingest` (UI uploads) or `_process_email`
(email reference docs) finds a PDF with no usable text layer, it renders the
pages and transcribes them with a vision model (`TRANSCRIPTION_MODEL`,
default `google/gemini-2.5-flash` — MUST be vision-capable; DeepSeek chat
models are text-only and will not work), then chunks and embeds the
transcription exactly like a text document. One page per request, in page
order, so a single bad page can't lose a whole document. Text-layer PDFs are
unaffected and never hit the vision model.

**Config:** `TRANSCRIPTION_MODEL` (default `google/gemini-2.5-flash`) and
`TRANSCRIPTION_MAX_PAGES` (default 200) via env vars.

**Cost:** ~$0.002/page with Gemini Flash, so a 200-page scanned spec book is
well under a dollar, once. Re-ingestion replaces chunks; it does not re-bill
unless re-triggered.

**Remaining nuance:** the triage (small-doc) vision path still caps at
`MAX_VISION_PAGES = 15` for fact extraction — see Limitation 6.4.

### 6.2 Email body not queryable

Only attachments/uploaded files are embedded. The email body that carried the
ITB is stored on the record but can't be referenced by the assistant.

### 6.3 Vector-only retrieval

`ask()` uses pure embedding similarity. Exact-token lookups (spec section
numbers like "28 46 00", codes like "NFPA 13") are a known weakness of
vector search; there's no keyword/hybrid component yet.

### 6.4 Vision page cap

`MAX_VISION_PAGES = 15` bounds triage vision cost; long scanned ITBs get
partial extraction (confidence score is expected to reflect this).

---

## 7. Build-Out Backlog

| # | Item | Notes | Effort |
|---|---|---|---|
| 1 | ~~Scanned-document RAG ingestion~~ **(DONE — closes Limitation 6.1)** | Implemented: `extractor.transcribe_scanned_pdf()` + branches in `_run_ingest` and `_process_email`. Deployed to Cloud Run. | — |
| 2 | Hybrid retrieval (keyword + vector) | Add Postgres `tsvector` column + GIN index; blend keyword rank with cosine distance in `ask()`. Improves spec-section/code lookups. | Small |
| 3 | Ingest email body as a source | In `_process_email`, `rag.ingest(rfp_id, "email-body", combined)` so the assistant can answer questions about the original email. | Small |
| 4 | Generation-model A/B evaluation | Fixed set of real ITBs through candidate models (DeepSeek-V3, Kimi K2 vs. Sonnet baseline); compare schema compliance, answer quality, cost. Set winner via env var. | Small |
| 5 | ANN index on embeddings | HNSW index on `document_chunks.embedding` if per-RFP chunk counts grow enough that filtered scans get slow. | Small |

---

## 8. Operations Cheat Sheet

- **Service deploy:** `gcloud run deploy rfp-triage --source rfp-triage-service --region us-central1 --project rfp-triage-poc --quiet` (from repo root). Preserves existing env vars/secrets. Service URL: `https://rfp-triage-599134526716.us-central1.run.app`.
- **Salesforce deploy:** see `Deployment.md` — full-path CLI invocation, org alias `NicksPersonal`, verified command syntax.
- **Auth:** Salesforce ↔ Cloud Run via OAuth 2.0 JWT bearer (Connected App + integration user); webhook/scheduler calls use shared-secret headers (`WEBHOOK_SECRET`, `POLL_SECRET`).
- **DB schema:** auto-created by `rag.init_schema()` (`document_chunks` + `ingest_jobs`).
- **GCS CORS:** `gcs-cors.json` enables direct browser uploads from the Salesforce domain.
