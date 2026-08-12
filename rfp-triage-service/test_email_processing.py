"""Tests for email-body-aware triage and attachment classification.

These mock the LLM, Salesforce, RAG, and GCS layers so the tests run offline
and fast. They exercise the routing logic in main.py: one Salesforce record
per email, small docs combined into the triage text, and large docs routed to
RAG + GCS only.
"""
import os
from unittest import mock

os.environ.setdefault("ANTHROPIC_API_KEY", "test")
os.environ.setdefault("SF_CLIENT_ID", "test")
os.environ.setdefault("SF_USERNAME", "test")
os.environ.setdefault("SF_PRIVATE_KEY", "test")
os.environ.setdefault("DATABASE_URL", "postgres://test")
os.environ.setdefault("GCS_BUCKET", "rfp-documents-poc")

import main  # noqa: E402
import config  # noqa: E402


def _facts(**overrides):
    base = {
        "rfp_name": "Test RFP",
        "issuing_organization": "City of Springfield",
        "due_date": "2026-12-01",
        "estimated_value": 250000,
        "geography": "Springfield, IL",
        "required_capabilities": ["fire apparatus"],
        "incumbent_vendor": None,
        "decision_timeline": "November 2026",
        "summary": "A test RFP.",
        "extraction_confidence": 90,
    }
    base.update(overrides)
    return base


def _fake_analyze(extraction):
    """Return facts regardless of extraction method."""
    return _facts()


def _fake_score(facts):
    return {"score": 80, "recommendation": "Pursue", "notes": facts["summary"]}


def _patch_deps():
    """Patch analyzer, salesforce, rag, storage, and config with lightweight
    fakes. config is patched (not the module-level env vars) so the gate flags
    work regardless of import order with other test files. Returns the mocks
    keyed by module name for assertions."""
    mocks = {
        "analyzer": mock.Mock(
            analyze_rfp=mock.Mock(side_effect=_fake_analyze),
            score_rfp=_fake_score),
        "salesforce_client": mock.Mock(
            create_rfp_record=mock.Mock(return_value={"rfpId": "a3cTEST"})),
        "rag": mock.Mock(ingest=mock.Mock(return_value=1)),
        "storage": mock.Mock(upload_reference_doc=mock.Mock(
            return_value="gs://rfp-documents-poc/a3cTEST/spec.pdf")),
        "config": mock.Mock(
            DATABASE_URL="postgres://test", GCS_BUCKET="rfp-documents-poc",
            TRIAGE_MAX_PAGES=30, TRIAGE_MAX_TEXT_CHARS=60000,
            WEBHOOK_SECRET=""),
    }
    patcher = mock.patch.multiple(main, **mocks)
    patcher.start()
    return mocks


# --- classify_attachment ---

def test_small_pdf_is_triage():
    with mock.patch("extractor.pdf_page_count", return_value=5):
        assert main.classify_attachment("itb.pdf", b"x" * 100) == "triage"


def test_large_pdf_is_reference():
    with mock.patch("extractor.pdf_page_count", return_value=50):
        assert main.classify_attachment("spec.pdf", b"x" * 100) == "reference"


def test_large_non_pdf_is_reference():
    assert main.classify_attachment("plans.docx", b"x" * 3_000_000) == "reference"


def test_small_non_pdf_is_triage():
    assert main.classify_attachment("letter.txt", b"x" * 100) == "triage"


def test_unreadable_pdf_is_reference():
    with mock.patch("extractor.pdf_page_count", side_effect=Exception("corrupt")):
        assert main.classify_attachment("broken.pdf", b"x" * 100) == "reference"


# --- _process_email ---

def test_body_only_creates_one_record():
    mocks = _patch_deps()
    try:
        result = main._process_email("ITB", "Body text here", "a@b.com", [])
    finally:
        mock.patch.stopall()

    assert result["status"] == "created"
    assert result["rfpId"] == "a3cTEST"
    # Exactly one Salesforce record per email.
    mocks["salesforce_client"].create_rfp_record.assert_called_once()
    # Combined text includes subject + body.
    combined = mocks["analyzer"].analyze_rfp.call_args.args[0].text
    assert "Subject: ITB" in combined
    assert "Body text here" in combined
    # No docs to ingest.
    mocks["rag"].ingest.assert_not_called()


def test_mixed_attachments_routes_large_doc_to_rag_and_gcs():
    small = ("letter.txt", b"Small letter body")
    large = ("spec.pdf", b"x" * 3_000_000)  # >2MB -> reference

    mocks = _patch_deps()
    with mock.patch("extractor.extract",
                    return_value=mock.Mock(method="Text",
                                           text="Small letter body")):
        result = main._process_email("ITB", "Body", "a@b.com", [small, large])
    mock.patch.stopall()

    assert result["status"] == "created"
    assert result["referenceDocs"] == ["spec.pdf"]
    # Exactly one Salesforce record regardless of attachment count.
    mocks["salesforce_client"].create_rfp_record.assert_called_once()
    # Small doc text included in combined; large doc NOT included.
    combined = mocks["analyzer"].analyze_rfp.call_args.args[0].text
    assert "Small letter body" in combined
    assert "x" * 3_000_000 not in combined
    # Large doc ingested into RAG and uploaded to GCS. The small triage doc
    # is also ingested, so expect both calls.
    mocks["rag"].ingest.assert_any_call(
        "a3cTEST", "spec.pdf", "Small letter body")
    mocks["storage"].upload_reference_doc.assert_called_once_with(
        "a3cTEST", "spec.pdf", large[1])


def test_multiple_attachments_still_one_record():
    docs = [("a.txt", b"AAA"), ("b.txt", b"BBB"), ("c.txt", b"CCC")]

    def fake_extract(file_bytes, filename):
        return mock.Mock(method="Text", text=file_bytes.decode())

    mocks = _patch_deps()
    with mock.patch("extractor.extract", side_effect=fake_extract):
        result = main._process_email("ITB", "Body", "a@b.com", docs)
    mock.patch.stopall()

    assert result["status"] == "created"
    mocks["salesforce_client"].create_rfp_record.assert_called_once()
    combined = mocks["analyzer"].analyze_rfp.call_args.args[0].text
    for txt in ("AAA", "BBB", "CCC"):
        assert txt in combined


# --- portal_url in Salesforce payload ---

def test_portal_url_included_in_payload():
    mocks = _patch_deps()
    mocks["analyzer"].analyze_rfp = mock.Mock(
        side_effect=lambda e: _facts(portal_url="https://bc.example.com/bid/123"))
    try:
        main._process_email("ITB", "Body", "a@b.com", [])
    finally:
        mock.patch.stopall()

    payload = mocks["salesforce_client"].create_rfp_record.call_args.args[0]
    assert payload["portalUrl"] == "https://bc.example.com/bid/123"


# --- /upload-url, /ingest, /summarize endpoints ---

def _client():
    main.app.config["TESTING"] = True
    return main.app.test_client()


def test_upload_url_requires_fields():
    mocks = _patch_deps()
    try:
        r = _client().post("/upload-url", json={"rfpId": "a3cTEST"})
        assert r.status_code == 400
    finally:
        mock.patch.stopall()


def test_upload_url_returns_signed_url():
    mocks = _patch_deps()
    mocks["storage"].generate_upload_url = mock.Mock(return_value={
        "uploadUrl": "https://storage.googleapis.com/signed",
        "gcsPath": "a3cTEST/spec.pdf"})
    try:
        r = _client().post("/upload-url", json={
            "rfpId": "a3cTEST", "filename": "spec.pdf",
            "contentType": "application/pdf"})
        assert r.status_code == 200
        assert r.get_json()["gcsPath"] == "a3cTEST/spec.pdf"
        mocks["storage"].generate_upload_url.assert_called_once_with(
            "a3cTEST", "spec.pdf", "application/pdf")
    finally:
        mock.patch.stopall()


def _wait_for_job(key, timeout=5.0):
    """Poll the in-memory job store until the background ingest thread finishes."""
    import time
    deadline = time.time() + timeout
    while time.time() < deadline:
        job = main._get_job(key)
        if job.get("status") in ("ingested", "skipped", "error"):
            return job
        time.sleep(0.05)
    return main._get_job(key)


def test_ingest_reads_gcs_and_ingests():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"spec text")
    try:
        with mock.patch("extractor.extract",
                        return_value=mock.Mock(method="Text", text="spec text")):
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "spec.pdf",
                "gcsPath": "a3cTEST/spec.pdf"})
        # Accepted for background processing.
        assert r.status_code == 202
        assert r.get_json()["status"] == "processing"
        # Wait for the worker thread, then verify it ingested.
        job = _wait_for_job("a3cTEST/spec.pdf")
        assert job["status"] == "ingested"
        mocks["rag"].ingest.assert_called_once_with(
            "a3cTEST", "spec.pdf", "spec text")
    finally:
        mock.patch.stopall()


def test_ingest_skips_vision_docs():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"scan")
    try:
        with mock.patch("extractor.extract",
                        return_value=mock.Mock(method="Vision", page_images=[])):
            r = _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "scan.pdf",
                "gcsPath": "a3cTEST/scan.pdf"})
        assert r.status_code == 202
        job = _wait_for_job("a3cTEST/scan.pdf")
        assert job["status"] == "skipped"
        mocks["rag"].ingest.assert_not_called()
    finally:
        mock.patch.stopall()


def test_ingest_status_endpoint_reports_job():
    mocks = _patch_deps()
    mocks["storage"].download_blob = mock.Mock(return_value=b"spec text")
    try:
        with mock.patch("extractor.extract",
                        return_value=mock.Mock(method="Text", text="spec text")):
            _client().post("/ingest", json={
                "rfpId": "a3cTEST", "filename": "spec.pdf",
                "gcsPath": "a3cTEST/spec.pdf"})
        _wait_for_job("a3cTEST/spec.pdf")
        r = _client().get("/ingest-status?rfpId=a3cTEST&filename=spec.pdf")
        assert r.status_code == 200
        assert r.get_json()["status"] == "ingested"
        assert r.get_json()["chunks"] == 1
    finally:
        mock.patch.stopall()


def test_ingest_status_unknown_job():
    mocks = _patch_deps()
    try:
        r = _client().get("/ingest-status?rfpId=nope&filename=nope.pdf")
        assert r.status_code == 200
        assert r.get_json()["status"] == "unknown"
    finally:
        mock.patch.stopall()


def test_summarize_returns_summary_with_citations():
    mocks = _patch_deps()
    mocks["rag"].get_context = mock.Mock(return_value={
        "context": "[spec.pdf chunk 0]\nScope: fire apparatus",
        "citations": [{"file": "spec.pdf", "chunk": 0, "excerpt": "Scope"}]})
    mocks["analyzer"].summarize_rfp = mock.Mock(return_value="A summary.")
    try:
        r = _client().post("/summarize", json={"rfpId": "a3cTEST"})
        assert r.status_code == 200
        body = r.get_json()
        assert body["summary"] == "A summary."
        assert body["citations"][0]["file"] == "spec.pdf"
    finally:
        mock.patch.stopall()


def test_summarize_no_docs():
    mocks = _patch_deps()
    mocks["rag"].get_context = mock.Mock(return_value={
        "context": "", "citations": []})
    try:
        r = _client().post("/summarize", json={"rfpId": "a3cTEST"})
        assert r.status_code == 200
        assert "No documents" in r.get_json()["summary"]
    finally:
        mock.patch.stopall()