"""GCS helpers for reference documents (spec books, plan sets).

Reference docs are routed to GCS for archival + vector DB ingestion rather
than being sent to the triage LLM. Uploads are best-effort: a failure here
must never break the Salesforce record creation.

Also provides V4 signed upload URLs so the Salesforce LWC can push large
files direct-to-GCS from the browser (bypassing the 6MB Apex callout limit),
then a reader to pull those bytes back for RAG ingestion.
"""
import datetime
import logging

import config

logger = logging.getLogger(__name__)


def _bucket():
    if not config.GCS_BUCKET:
        raise RuntimeError("GCS_BUCKET is not configured")
    from google.cloud import storage
    return storage.Client().bucket(config.GCS_BUCKET)


def upload_reference_doc(rfp_id: str, filename: str, file_bytes: bytes) -> str:
    """Upload raw bytes to GCS under {rfp_id}/{filename}.

    Returns the gs:// URI. Raises if GCS isn't configured or the upload fails.
    """
    bucket = _bucket()
    blob = bucket.blob(f"{rfp_id}/{filename}")
    blob.upload_from_string(file_bytes)
    logger.info("Uploaded %s to gs://%s/%s/%s",
                filename, config.GCS_BUCKET, rfp_id, filename)
    return f"gs://{config.GCS_BUCKET}/{rfp_id}/{filename}"


def generate_upload_url(rfp_id: str, filename: str,
                        content_type: str) -> dict:
    """Create a V4 signed PUT URL so the browser can upload direct-to-GCS.

    Returns {"uploadUrl": ..., "gcsPath": "{rfp_id}/{filename}"}. The LWC PUTs
    the file bytes to uploadUrl, then calls /ingest with the gcsPath.
    """
    bucket = _bucket()
    gcs_path = f"{rfp_id}/{filename}"
    blob = bucket.blob(gcs_path)
    url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=15),
        method="PUT",
        content_type=content_type or "application/octet-stream",
    )
    logger.info("Issued signed upload URL for %s", gcs_path)
    return {"uploadUrl": url, "gcsPath": gcs_path}


def download_blob(gcs_path: str) -> bytes:
    """Read an object's bytes back from GCS (used by /ingest after the LWC
    has uploaded direct-to-GCS)."""
    bucket = _bucket()
    blob = bucket.blob(gcs_path)
    return blob.download_as_bytes()