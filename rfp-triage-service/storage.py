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

    On Cloud Run the metadata-server credentials hold only a token, not a
    private key, so we sign via the IAM Credentials API (signBlob) by passing
    the runtime service account's email + a current access token. This needs
    roles/iam.serviceAccountTokenCreator on the runtime SA (granted to itself).
    """
    import google.auth
    from google.auth.transport import requests as auth_requests

    credentials, _ = google.auth.default()
    credentials.refresh(auth_requests.Request())

    bucket = _bucket()
    gcs_path = f"{rfp_id}/{filename}"
    blob = bucket.blob(gcs_path)
    url = blob.generate_signed_url(
        version="v4",
        expiration=datetime.timedelta(minutes=15),
        method="PUT",
        content_type=content_type or "application/octet-stream",
        service_account_email=credentials.service_account_email,
        access_token=credentials.token,
    )
    logger.info("Issued signed upload URL for %s", gcs_path)
    return {"uploadUrl": url, "gcsPath": gcs_path}


def download_blob(gcs_path: str) -> bytes:
    """Read an object's bytes back from GCS (used by /ingest after the LWC
    has uploaded direct-to-GCS)."""
    bucket = _bucket()
    blob = bucket.blob(gcs_path)
    return blob.download_as_bytes()


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
    if not gcs_paths:
        return {}
    import google.auth
    from google.auth.transport import requests as auth_requests

    credentials, _ = google.auth.default()
    credentials.refresh(auth_requests.Request())
    bucket = _bucket()
    urls = {}
    for uri in gcs_paths:
        # uri is gs://bucket/path -> strip the scheme + bucket to get path
        prefix = f"gs://{config.GCS_BUCKET}/"
        path = uri[len(prefix):] if uri.startswith(prefix) else uri
        blob = bucket.blob(path)
        urls[uri] = blob.generate_signed_url(
            version="v4",
            expiration=datetime.timedelta(minutes=ttl_minutes),
            method="GET",
            service_account_email=credentials.service_account_email,
            access_token=credentials.token,
        )
    return urls
