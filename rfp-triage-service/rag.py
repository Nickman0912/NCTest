"""RAG (Retrieval-Augmented Generation) for deep-dive Q&A on RFP documents.

Flow:
1. ingest(): chunk document text, embed each chunk via OpenRouter, store
   in Cloud SQL Postgres + pgvector, tagged with the Salesforce RFP record ID.
2. ask(): embed the question, find nearest chunks for that record, send
   ONLY those chunks to the LLM with the question, return answer + citations.

The LLM never sees the whole document - only the handful of relevant
paragraphs - which is what keeps long spec books reliable.
"""
import base64
import logging
import uuid

import psycopg
from pgvector.psycopg import register_vector

import config

logger = logging.getLogger(__name__)

EMBEDDING_MODEL = "openai/text-embedding-3-small"
EMBEDDING_DIMS = 1536
CHUNK_SIZE = 1200        # characters per chunk
CHUNK_OVERLAP = 200      # overlap so sentences aren't split mid-thought
TOP_K = 6                # chunks retrieved per question

DDL = f"""
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE IF NOT EXISTS document_chunks (
    id UUID PRIMARY KEY,
    rfp_id TEXT NOT NULL,          -- Salesforce RFP__c record ID
    source_file TEXT NOT NULL,
    chunk_index INT NOT NULL,
    content TEXT NOT NULL,
    embedding vector({EMBEDDING_DIMS})
);
CREATE INDEX IF NOT EXISTS idx_chunks_rfp ON document_chunks (rfp_id);
CREATE TABLE IF NOT EXISTS ingest_jobs (
    job_key TEXT PRIMARY KEY,        -- rfp_id/filename
    rfp_id TEXT NOT NULL,
    filename TEXT NOT NULL,
    status TEXT NOT NULL,            -- processing | ingested | skipped | error
    chunks INT,
    reason TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS page_images (
    id UUID PRIMARY KEY,
    rfp_id TEXT NOT NULL,
    source_file TEXT NOT NULL,
    page INT NOT NULL,
    gcs_uri TEXT NOT NULL,
    visual_description TEXT,
    embedding vector({EMBEDDING_DIMS})
);
CREATE INDEX IF NOT EXISTS idx_page_images_rfp ON page_images (rfp_id);
"""


def _connect():
    conn = psycopg.connect(config.DATABASE_URL, autocommit=True)
    register_vector(conn)
    return conn


def init_schema() -> None:
    with _connect() as conn:
        conn.execute(DDL)
    logger.info("Vector schema ready")


# --- Ingest job tracking (Postgres-backed, survives instance recycling) ---

def set_job(job_key: str, rfp_id: str, filename: str, status: str,
            chunks: int = None, reason: str = None) -> None:
    """Create or update an ingest job. Persists across Cloud Run instances."""
    with _connect() as conn:
        conn.execute(
            "INSERT INTO ingest_jobs (job_key, rfp_id, filename, status, "
            "chunks, reason, updated_at) VALUES (%s,%s,%s,%s,%s,%s,now()) "
            "ON CONFLICT (job_key) DO UPDATE SET status=EXCLUDED.status, "
            "chunks=EXCLUDED.chunks, reason=EXCLUDED.reason, updated_at=now()",
            (job_key, rfp_id, filename, status, chunks, reason))


def get_job(job_key: str) -> dict:
    """Return the job dict, or {} if unknown."""
    with _connect() as conn:
        row = conn.execute(
            "SELECT status, chunks, reason, filename FROM ingest_jobs "
            "WHERE job_key = %s", (job_key,)).fetchone()
    if not row:
        return {}
    return {"status": row[0], "chunks": row[1], "reason": row[2],
            "filename": row[3]}


def list_documents(rfp_id: str) -> list[dict]:
    """Return the documents already ingested for an RFP, with chunk counts.

    Drives the LWC's 'already uploaded' list so a user can see what's been
    indexed and doesn't re-upload the same file. Ordered by filename.
    """
    with _connect() as conn:
        rows = conn.execute(
            "SELECT source_file, COUNT(*) AS chunks "
            "FROM document_chunks WHERE rfp_id = %s "
            "GROUP BY source_file ORDER BY source_file",
            (rfp_id,)).fetchall()
    return [{"filename": r[0], "chunks": r[1]} for r in rows]


def _embed(texts: list[str]) -> list[list[float]]:
    from openai import OpenAI
    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)
    resp = client.embeddings.create(model=EMBEDDING_MODEL, input=texts)
    return [d.embedding for d in resp.data]


def _chunk(text: str) -> list[str]:
    """Split text into overlapping chunks on paragraph boundaries."""
    paragraphs = [p.strip() for p in text.split("\n") if p.strip()]
    chunks, current = [], ""
    for para in paragraphs:
        if len(current) + len(para) > CHUNK_SIZE and current:
            chunks.append(current)
            current = current[-CHUNK_OVERLAP:] + "\n" + para
        else:
            current = f"{current}\n{para}" if current else para
    if current:
        chunks.append(current)
    return chunks


def ingest(rfp_id: str, source_file: str, text: str) -> int:
    """Chunk + embed + store a document. Returns chunk count."""
    chunks = _chunk(text)
    if not chunks:
        return 0

    # Embed in batches of 50 (API limit safety).
    embeddings = []
    for i in range(0, len(chunks), 50):
        embeddings.extend(_embed(chunks[i:i + 50]))

    with _connect() as conn:
        # Idempotent: re-ingesting a file replaces its chunks.
        conn.execute(
            "DELETE FROM document_chunks WHERE rfp_id = %s AND source_file = %s",
            (rfp_id, source_file))
        for idx, (chunk, emb) in enumerate(zip(chunks, embeddings)):
            conn.execute(
                "INSERT INTO document_chunks (id, rfp_id, source_file, "
                "chunk_index, content, embedding) VALUES (%s,%s,%s,%s,%s,%s)",
                (str(uuid.uuid4()), rfp_id, source_file, idx, chunk, emb))
    logger.info("Ingested %d chunks for RFP %s from %s",
                len(chunks), rfp_id, source_file)
    return len(chunks)


def get_context(rfp_id: str, max_chunks: int = 40) -> dict:
    """Pull a representative cross-section of an RFP's chunks for summarization.

    Unlike ask(), this isn't similarity-ranked against a question - it samples
    chunks spread across each source file so the summary covers the whole
    document, not just one theme. Returns {"context": str, "citations": [...]}.
    """
    with _connect() as conn:
        rows = conn.execute(
            "SELECT source_file, chunk_index, content "
            "FROM document_chunks WHERE rfp_id = %s "
            "ORDER BY source_file, chunk_index",
            (rfp_id,)).fetchall()

    if not rows:
        return {"context": "", "citations": []}

    # Evenly sample up to max_chunks across the full set so long spec books
    # are represented end-to-end rather than just their opening pages.
    step = max(1, len(rows) // max_chunks)
    sampled = rows[::step][:max_chunks]

    context = "\n\n---\n\n".join(
        f"[{r[0]} chunk {r[1]}]\n{r[2]}" for r in sampled)
    return {
        "context": context,
        # Full chunk content so the LWC can show the entire source subsection.
        "citations": [{"file": r[0], "chunk": r[1], "excerpt": r[2]}
                      for r in sampled],
    }


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


def _gcs_uri_to_data_url(gcs_uri: str) -> str:
    """Download a page image and return a data: URL for vision input."""
    import storage
    path = gcs_uri.split(f"gs://{config.GCS_BUCKET}/", 1)[-1]
    png = storage.download_blob(path)
    return "data:image/png;base64," + base64.b64encode(png).decode()


def ask(rfp_id: str, question: str) -> dict:
    """Answer a question using only chunks from this RFP's documents."""
    question_emb = _embed([question])[0]

    with _connect() as conn:
        rows = conn.execute(
            "SELECT source_file, chunk_index, content, "
            "       embedding <=> %s::vector AS distance "
            "FROM document_chunks WHERE rfp_id = %s "
            "ORDER BY distance LIMIT %s",
            (str(question_emb), rfp_id, TOP_K)).fetchall()

    if not rows:
        return {"answer": "No documents have been ingested for this RFP yet.",
                "citations": []}

    context = "\n\n---\n\n".join(
        f"[{r[0]} chunk {r[1]}]\n{r[2]}" for r in rows)

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
        try:
            data_url = _gcs_uri_to_data_url(hit["gcs_uri"])
            content.append({
                "type": "text",
                "text": f"PAGE IMAGE: {hit['file']} page {hit['page']}",
            })
            content.append({
                "type": "image_url",
                "image_url": {"url": data_url},
            })
        except Exception:
            logger.exception("Failed to load page image for %s page %d",
                             hit["file"], hit["page"])

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
        "citations": [{"file": r[0], "chunk": r[1],
                       "excerpt": r[2]} for r in rows],
        "image_citations": image_citations,
    }
