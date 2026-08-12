"""RFP triage service - Flask app for Cloud Run.

Endpoints:
  GET  /health          liveness check (no auth)
  POST /webhook/email   inbound email with RFP attachment(s)
                        (SendGrid Inbound Parse multipart format, or a
                         simple JSON POST with base64 files - see README)
"""
import base64
import logging
import threading

from flask import Flask, jsonify, request

import analyzer
import config
import extractor
from extractor import ExtractionResult
import gmail_client
import graph_client
import rag
import salesforce_client
import storage


def _mail_client():
    return gmail_client if config.MAIL_PROVIDER == "gmail" else graph_client

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)

# Ingest job state is persisted in Postgres (rag.set_job/get_job) so it
# survives Cloud Run instance recycling - an in-memory dict would be wiped
# whenever the instance scales down or is replaced mid-job.

# Ensure the vector + ingest_jobs tables exist. Runs on startup inside Cloud
# Run, where the Cloud SQL unix socket is reachable. Best-effort: if the DB
# isn't configured (local testing), skip without crashing.
if config.DATABASE_URL:
    try:
        rag.init_schema()
    except Exception:
        logger.exception("Could not initialize database schema")


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


UPLOAD_PAGE = """<!doctype html>
<html><head><title>RFP Triage</title>
<meta name=viewport content="width=device-width,initial-scale=1">
<style>
 body{font-family:system-ui,sans-serif;max-width:640px;margin:40px auto;padding:0 16px;background:#f8f9fa;color:#222}
 h1{font-size:1.4rem}
 #drop{border:2px dashed #999;border-radius:12px;padding:48px 16px;text-align:center;background:#fff;cursor:pointer}
 #drop.over{border-color:#2563eb;background:#eff6ff}
 #status{margin-top:16px;white-space:pre-wrap;font-size:.9rem}
 .card{background:#fff;border:1px solid #e5e7eb;border-radius:8px;padding:16px;margin-top:12px}
 .score{font-size:2rem;font-weight:700}
 .Pursue{color:#16a34a}.Review{color:#d97706}.Decline{color:#dc2626}
 a{color:#2563eb}
</style></head><body>
<h1>RFP Triage</h1>
<p>Drop an RFP document (PDF, DOCX, TXT) to analyze it and create a Salesforce record.</p>
<div id=drop>Drag &amp; drop a file here, or click to browse
<input type=file id=file hidden accept=".pdf,.docx,.txt"></div>
<div id=status></div>
<script>
const drop=document.getElementById('drop'),file=document.getElementById('file'),
      status=document.getElementById('status');
drop.onclick=()=>file.click();
file.onchange=()=>upload(file.files[0]);
drop.ondragover=e=>{e.preventDefault();drop.classList.add('over')};
drop.ondragleave=()=>drop.classList.remove('over');
drop.ondrop=e=>{e.preventDefault();drop.classList.remove('over');upload(e.dataTransfer.files[0])};
async function upload(f){
 if(!f)return;
 status.textContent='Analyzing '+f.name+'... (LLM call, ~10-20s)';
 const fd=new FormData();fd.append('attachment',f);
 try{
  const r=await fetch('/webhook/email',{method:'POST',body:fd,
   headers:{'X-Webhook-Secret':new URLSearchParams(location.search).get('key')||''}});
  const j=await r.json();
  status.innerHTML=(j.results||[]).map(o=>o.status==='created'
   ?`<div class=card><div class="score ${o.recommendation}">${o.score} &mdash; ${o.recommendation}</div>
     <div>Salesforce record: <b>${o.rfpId}</b></div></div>`
   :`<div class=card>${o.file}: ${o.status}${o.reason?' - '+o.reason:''}</div>`).join('')
   ||JSON.stringify(j);
 }catch(e){status.textContent='Error: '+e}
}
</script></body></html>"""


@app.post("/ask")
def ask_question():
    """Deep-dive Q&A over an RFP's ingested documents.
    Body: {"rfpId": "a3c...", "question": "What are the liquidated damages?"}
    """
    if config.WEBHOOK_SECRET:
        if request.headers.get("X-Webhook-Secret") != config.WEBHOOK_SECRET:
            return jsonify({"error": "unauthorized"}), 401
    if not config.DATABASE_URL:
        return jsonify({"error": "RAG not configured"}), 500

    body = request.get_json(silent=True) or {}
    rfp_id, question = body.get("rfpId"), body.get("question")
    if not rfp_id or not question:
        return jsonify({"error": "rfpId and question are required"}), 400

    try:
        return jsonify(rag.ask(rfp_id, question)), 200
    except Exception:
        logger.exception("RAG query failed")
        return jsonify({"error": "query failed"}), 500


def _authorized() -> bool:
    return (not config.WEBHOOK_SECRET
            or request.headers.get("X-Webhook-Secret") == config.WEBHOOK_SECRET)


@app.post("/upload-url")
def upload_url():
    """Issue a V4 signed GCS PUT URL so the LWC can upload a large document
    direct-to-GCS (bypassing the 6MB Apex callout limit).
    Body: {"rfpId": "a3c...", "filename": "spec.pdf", "contentType": "application/pdf"}
    """
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401
    if not config.GCS_BUCKET:
        return jsonify({"error": "GCS not configured"}), 500

    body = request.get_json(silent=True) or {}
    rfp_id, filename = body.get("rfpId"), body.get("filename")
    if not rfp_id or not filename:
        return jsonify({"error": "rfpId and filename are required"}), 400

    try:
        result = storage.generate_upload_url(
            rfp_id, filename, body.get("contentType", ""))
        return jsonify(result), 200
    except Exception:
        logger.exception("Could not generate upload URL")
        return jsonify({"error": "could not generate upload url"}), 500


@app.post("/ingest")
def ingest_document():
    """After the LWC has uploaded a file direct-to-GCS, kick off ingestion in
    the background and return 202 immediately. Large spec books take longer
    than the 60s Apex callout timeout to download + extract + embed, so the
    work runs in a thread and the LWC polls /ingest-status for completion.
    Body: {"rfpId": "a3c...", "filename": "spec.pdf", "gcsPath": "a3c.../spec.pdf"}
    """
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401
    if not config.DATABASE_URL:
        return jsonify({"error": "RAG not configured"}), 500

    body = request.get_json(silent=True) or {}
    rfp_id, filename, gcs_path = (body.get("rfpId"), body.get("filename"),
                                  body.get("gcsPath"))
    if not rfp_id or not filename or not gcs_path:
        return jsonify({"error": "rfpId, filename and gcsPath are required"}), 400

    key = f"{rfp_id}/{filename}"
    rag.set_job(key, rfp_id, filename, "processing")
    threading.Thread(
        target=_run_ingest,
        args=(key, rfp_id, filename, gcs_path),
        daemon=True,
    ).start()
    return jsonify({"status": "processing"}), 202


def _run_ingest(key, rfp_id, filename, gcs_path):
    """Background worker: download from GCS, extract text, embed + store."""
    try:
        file_bytes = storage.download_blob(gcs_path)
    except Exception:
        logger.exception("Could not download %s from GCS", gcs_path)
        rag.set_job(key, rfp_id, filename, "error",
                    reason="could not read uploaded file")
        return

    try:
        # Text-only extraction: never renders page images, so scanned PDFs
        # (common for construction document sets) are detected and skipped in
        # seconds rather than after rendering every page.
        text = extractor.extract_text_only(file_bytes, filename)
        if len(text) < extractor.MIN_TEXT_CHARS:
            logger.info("Skipping %s: scanned/image-only document (%d chars)",
                        filename, len(text))
            rag.set_job(key, rfp_id, filename, "skipped",
                        reason="scanned/image-only document (no text layer)")
            return
        chunks = rag.ingest(rfp_id, filename, text)
        logger.info("Ingested %s -> %d chunks", key, chunks)
        rag.set_job(key, rfp_id, filename, "ingested", chunks=chunks)
    except ValueError as e:
        logger.warning("Could not ingest %s: %s", filename, e)
        rag.set_job(key, rfp_id, filename, "skipped", reason=str(e))
    except Exception:
        logger.exception("Ingestion failed for %s", filename)
        rag.set_job(key, rfp_id, filename, "error", reason="ingestion failed")


@app.get("/ingest-status")
def ingest_status():
    """Report the status of a background ingest job.
    Query: ?rfpId=a3c...&filename=spec.pdf"""
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401

    rfp_id = request.args.get("rfpId")
    filename = request.args.get("filename")
    if not rfp_id or not filename:
        return jsonify({"error": "rfpId and filename are required"}), 400

    job = rag.get_job(f"{rfp_id}/{filename}")
    if not job:
        return jsonify({"status": "unknown"}), 200
    return jsonify(job), 200


@app.get("/documents")
def list_documents():
    """List documents already ingested for an RFP so the LWC can show what's
    been indexed (and prevent duplicate re-uploads).
    Query: ?rfpId=a3c..."""
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401
    if not config.DATABASE_URL:
        return jsonify({"error": "RAG not configured"}), 500

    rfp_id = request.args.get("rfpId")
    if not rfp_id:
        return jsonify({"error": "rfpId is required"}), 400

    try:
        return jsonify({"documents": rag.list_documents(rfp_id)}), 200
    except Exception:
        logger.exception("Could not list documents")
        return jsonify({"error": "could not list documents"}), 500


@app.post("/summarize")
def summarize():
    """Generate a project summary + recommendation from an RFP's ingested
    documents. Body: {"rfpId": "a3c..."}"""
    if not _authorized():
        return jsonify({"error": "unauthorized"}), 401
    if not config.DATABASE_URL:
        return jsonify({"error": "RAG not configured"}), 500

    body = request.get_json(silent=True) or {}
    rfp_id = body.get("rfpId")
    if not rfp_id:
        return jsonify({"error": "rfpId is required"}), 400

    try:
        ctx = rag.get_context(rfp_id)
        if not ctx["context"]:
            return jsonify({
                "summary": "No documents have been ingested for this RFP yet.",
                "citations": []}), 200
        summary = analyzer.summarize_rfp(ctx["context"])
        return jsonify({"summary": summary,
                        "citations": ctx["citations"]}), 200
    except Exception:
        logger.exception("Summarization failed")
        return jsonify({"error": "summarization failed"}), 500


@app.get("/")
def upload_page():
    """Demo UI. Same shared secret as the webhook, passed as ?key=."""
    if config.WEBHOOK_SECRET:
        if request.args.get("key") != config.WEBHOOK_SECRET:
            return "Append ?key=... to the URL (same secret as the webhook).", 401
    return UPLOAD_PAGE


@app.post("/webhook/email")
def inbound_email():
    # Cheap shared-secret check so random internet traffic can't create records.
    if config.WEBHOOK_SECRET:
        if request.headers.get("X-Webhook-Secret") != config.WEBHOOK_SECRET:
            return jsonify({"error": "unauthorized"}), 401

    source_email = request.form.get("from") or request.values.get("from", "")
    subject = request.form.get("subject") or request.values.get("subject", "")
    body_text = request.form.get("text") or request.values.get("text", "")

    # Collect attachments: multipart files (SendGrid) or JSON base64 list.
    attachments = _get_attachments()
    if not attachments:
        return jsonify({"error": "no attachments found"}), 400

    try:
        result = _process_email(subject, body_text, source_email, attachments)
    except ValueError as e:
        logger.warning("Skipping email: %s", e)
        return jsonify({"results": [{"status": "skipped",
                                      "reason": str(e)}]}), 200
    except Exception:
        logger.exception("Failed to process email")
        return jsonify({"results": [{"status": "error"}]}), 200

    return jsonify({"results": [result]}), 200


@app.post("/poll")
def poll_mailbox():
    """Triggered by Cloud Scheduler. Reads unread RFP emails from the
    mailbox via Graph, processes each, and marks them with a category."""
    expected = config.POLL_SECRET or config.WEBHOOK_SECRET
    if expected and request.headers.get("X-Poll-Secret") != expected:
        return jsonify({"error": "unauthorized"}), 401

    mail = _mail_client()
    if config.MAIL_PROVIDER == "gmail":
        configured = config.GMAIL_CLIENT_ID and config.GMAIL_REFRESH_TOKEN
    else:
        configured = (config.MS_TENANT_ID and config.MS_CLIENT_ID
                      and config.MS_CLIENT_SECRET and config.MS_MAILBOX)
    if not configured:
        return jsonify({"error": f"{config.MAIL_PROVIDER} not configured"}), 500

    messages = mail.fetch_unread_with_attachments()
    logger.info("Poll found %d unread messages with attachments", len(messages))

    results = []
    for msg in messages:
        # Gmail returns {"from": "Name <addr@x.com>"}; Graph nests it.
        raw_from = msg.get("from", "")
        if isinstance(raw_from, dict):
            sender = raw_from.get("emailAddress", {}).get("address", "")
        else:
            sender = raw_from.split("<")[-1].rstrip(">").strip()
        subject = msg.get("subject", "")
        body_text = msg.get("body", "")
        attachments = mail.get_attachments(msg["id"])

        try:
            outcome = _process_email(subject, body_text, sender, attachments)
        except ValueError as e:
            logger.warning("Skipping email %s: %s", msg["id"], e)
            outcome = {"status": "skipped", "reason": str(e)}
        except Exception:
            logger.exception("Failed to process email %s", msg["id"])
            outcome = {"status": "error"}

        # Categorize so the mailbox itself becomes the audit trail.
        try:
            if outcome.get("status") == "created":
                mail.mark_processed(
                    msg["id"],
                    f"{outcome['recommendation']} ({outcome['score']})")
            else:
                mail.mark_processed(msg["id"], "Needs review")
        except Exception:
            logger.exception("Could not mark message %s processed", msg["id"])

        results.append({"message": subject, "from": sender,
                        "attachments": [outcome]})

    return jsonify({"processed": len(results), "results": results}), 200


def _get_attachments() -> list[tuple[str, bytes]]:
    """Support both SendGrid multipart and plain-JSON base64 posts."""
    if request.content_type and "multipart/form-data" in request.content_type:
        return [(f.filename, f.read()) for f in request.files.values()
                if f.filename]

    body = request.get_json(silent=True) or {}
    return [
        (a["filename"], base64.b64decode(a["content"]))
        for a in body.get("attachments", [])
        if a.get("filename") and a.get("content")
    ]


def classify_attachment(filename: str, file_bytes: bytes) -> str:
    """Return 'triage' (read by triage LLM) or 'reference' (GCS + vector DB only)."""
    if filename.lower().endswith(".pdf"):
        try:
            if extractor.pdf_page_count(file_bytes) > config.TRIAGE_MAX_PAGES:
                return "reference"
        except Exception:
            return "reference"  # unreadable PDFs shouldn't block triage
    if len(file_bytes) > 2_000_000:  # >2MB non-PDF
        return "reference"
    return "triage"


def _process_email(subject: str, body_text: str, source_email: str,
                   attachments: list[tuple[str, bytes]]) -> dict:
    """Treat one email as a single unit: combine body + small attachments into
    one triage analysis producing ONE Salesforce record. Large reference docs
    are routed to GCS + vector DB ingestion only."""
    logger.info("Processing email '%s' with %d attachment(s)",
                subject, len(attachments))

    # 1. Split attachments by classification.
    triage_docs, reference_docs = [], []
    for filename, file_bytes in attachments:
        if classify_attachment(filename, file_bytes) == "triage":
            triage_docs.append((filename, file_bytes))
        else:
            reference_docs.append((filename, file_bytes))

    # 2. Build combined triage text: email body + small attachment text.
    combined = f"Subject: {subject}\n\n{body_text}\n"
    extracted_texts = {}  # saved for RAG ingestion later
    vision_summaries = []  # summaries from vision-path small docs
    for filename, file_bytes in triage_docs:
        try:
            result = extractor.extract(file_bytes, filename)
            if result.method == "Text":
                extracted_texts[filename] = result.text
                combined += f"\n\n--- ATTACHMENT: {filename} ---\n{result.text}"
            else:
                # Vision-path small docs (scanned ITB letters): analyze them
                # separately and merge the summary into the combined text.
                vision_facts = analyzer.analyze_rfp(result)
                vision_summaries.append(
                    f"\n\n--- ATTACHMENT: {filename} (scan) ---\n"
                    f"{vision_facts.get('summary', '')}")
        except ValueError as e:
            logger.warning("Skipping %s: %s", filename, e)

    combined += "".join(vision_summaries)
    combined = combined[:config.TRIAGE_MAX_TEXT_CHARS]

    # 3. ONE LLM analysis + scoring on the combined text.
    facts = analyzer.analyze_rfp(ExtractionResult(method="Text", text=combined))
    scoring = analyzer.score_rfp(facts)

    # 4. Create ONE Salesforce record; attach the first available attachment
    #    as the source document (or none if body-only).
    source_filename, source_bytes = (triage_docs[0] if triage_docs
                                     else (reference_docs[0] if reference_docs
                                           else (None, None)))
    payload = {
        "rfpName": facts.get("rfp_name"),
        "issuingOrganization": facts.get("issuing_organization"),
        "dueDate": facts.get("due_date"),
        "estimatedValue": facts.get("estimated_value"),
        "geography": facts.get("geography"),
        "requiredCapabilities": "\n".join(facts.get("required_capabilities", [])),
        "incumbentVendor": facts.get("incumbent_vendor"),
        "decisionTimeline": facts.get("decision_timeline"),
        "pursuitScore": scoring["score"],
        "extractionConfidence": facts.get("extraction_confidence"),
        "extractionMethod": "Text",
        "recommendation": scoring["recommendation"],
        "recommendationNotes": scoring["notes"],
        "sourceEmail": source_email,
        "portalUrl": facts.get("portal_url"),
        # Attach original file; skip if huge to keep request sizes sane.
        "documentBase64": (base64.b64encode(source_bytes).decode()
                            if source_bytes and len(source_bytes) < 4_500_000
                            else None),
        "documentFileName": source_filename or "",
    }

    sf_resp = salesforce_client.create_rfp_record(payload)
    rfp_id = sf_resp["rfpId"]

    # 5. RAG ingestion (best-effort, after record exists):
    #    - extracted_texts from triage docs
    #    - reference docs: extract text (text path only; skip vision for v1),
    #      call rag.ingest, and upload raw bytes to GCS if configured.
    if config.DATABASE_URL:
        for filename, text in extracted_texts.items():
            try:
                rag.ingest(rfp_id, filename, text)
            except Exception:
                logger.exception("RAG ingestion failed for %s", filename)

        for filename, file_bytes in reference_docs:
            try:
                result = extractor.extract(file_bytes, filename)
                if result.method == "Text":
                    rag.ingest(rfp_id, filename, result.text)
                else:
                    # Vision extraction for reference docs is out of scope for
                    # v1 - log and skip.
                    logger.info("Skipping vision ingestion for reference doc %s",
                                filename)
            except ValueError as e:
                logger.warning("Skipping reference doc %s: %s", filename, e)

    # Reference docs also uploaded to GCS if configured.
    if config.GCS_BUCKET:
        for filename, file_bytes in reference_docs:
            try:
                storage.upload_reference_doc(rfp_id, filename, file_bytes)
            except Exception:
                logger.exception("GCS upload failed for %s", filename)

    return {
        "file": source_filename or subject,
        "status": "created",
        "rfpId": rfp_id,
        "score": scoring["score"],
        "recommendation": scoring["recommendation"],
        "confidence": facts.get("extraction_confidence"),
        "method": "Text",
        "referenceDocs": [f for f, _ in reference_docs],
    }


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=config.PORT)
