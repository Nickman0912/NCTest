"""RAG (Retrieval-Augmented Generation) for deep-dive Q&A on RFP documents.

Flow:
1. ingest(): chunk document text, embed each chunk via OpenRouter, store
   in Cloud SQL Postgres + pgvector, tagged with the Salesforce RFP record ID.
2. ask(): embed the question, find nearest chunks for that record, send
   ONLY those chunks to the LLM with the question, return answer + citations.

The LLM never sees the whole document - only the handful of relevant
paragraphs - which is what keeps long spec books reliable.
"""
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

    from openai import OpenAI
    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)
    resp = client.chat.completions.create(
        model=config.GENERATION_MODEL,
        max_tokens=1000,
        messages=[{
            "role": "user",
            "content": (
                "You are helping a construction estimator review bid documents. "
                "Answer the question using ONLY the excerpts below. If the "
                "answer isn't in the excerpts, say so plainly - do not guess. "
                "Cite which excerpt each fact came from.\n\n"
                f"EXCERPTS:\n{context}\n\nQUESTION: {question}"
            ),
        }],
    )

    return {
        "answer": resp.choices[0].message.content,
        # Full chunk content so the LWC can show the entire source subsection.
        "citations": [{"file": r[0], "chunk": r[1],
                       "excerpt": r[2]} for r in rows],
    }
