"""Configuration for the RFP triage service.

Everything is driven by environment variables so the same image runs
locally (for testing) and on Cloud Run (with values from Secret Manager).
"""
import os

# --- Cloud SQL (pgvector) for RAG deep-dive ---
DATABASE_URL = os.environ.get("DATABASE_URL", "")

# --- Flask ---
PORT = int(os.environ.get("PORT", "8080"))

# --- LLM provider: 'openrouter' (default) or 'anthropic' ---
LLM_PROVIDER = os.environ.get("LLM_PROVIDER", "openrouter")

OPENROUTER_API_KEY = os.environ.get("OPENROUTER_API_KEY", "")

# Per-task model routing. Each stage can be tuned independently for cost vs.
# quality. All default to cheap-but-capable models; override via env vars.
#
# EXTRACTION_MODEL: structured fact extraction from the ITB (high volume,
#   schema-following - a mini/flash model is plenty).
EXTRACTION_MODEL = os.environ.get(
    "EXTRACTION_MODEL", "google/gemini-2.5-flash")
# GENERATION_MODEL: user-facing Q&A + summaries (lower volume, quality
#   visible to estimators - worth a stronger model).
GENERATION_MODEL = os.environ.get(
    "GENERATION_MODEL", "anthropic/claude-sonnet-4.5")
# VISION_MODEL: scanned/image-only documents.
VISION_MODEL = os.environ.get("VISION_MODEL", "openai/gpt-4o-mini")
# TRANSCRIPTION_MODEL: vision model used to transcribe scanned PDF pages to
#   text for RAG ingestion. MUST be vision-capable (DeepSeek chat models are
#   text-only and will NOT work here). Gemini 2.5 Flash is the cheap default.
TRANSCRIPTION_MODEL = os.environ.get(
    "TRANSCRIPTION_MODEL", "google/gemini-2.5-flash")
# Cap pages transcribed per document so a runaway scan can't blow up cost or
# the background thread's runtime. Generous for real spec books.
TRANSCRIPTION_MAX_PAGES = int(os.environ.get("TRANSCRIPTION_MAX_PAGES", "200"))

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

# Back-compat shim: older code referenced OPENROUTER_MODEL as the single
# generation model. Keep it as the extraction default.
OPENROUTER_MODEL = os.environ.get("OPENROUTER_MODEL", EXTRACTION_MODEL)

ANTHROPIC_API_KEY = os.environ.get("ANTHROPIC_API_KEY", "")
ANTHROPIC_MODEL = os.environ.get("ANTHROPIC_MODEL", "claude-haiku-4-5-20251001")

# --- Salesforce (OAuth 2.0 JWT bearer flow) ---
SF_LOGIN_URL = os.environ.get("SF_LOGIN_URL", "https://login.salesforce.com")
SF_CLIENT_ID = os.environ["SF_CLIENT_ID"]          # Connected App consumer key
SF_USERNAME = os.environ["SF_USERNAME"]            # integration user
SF_PRIVATE_KEY = os.environ["SF_PRIVATE_KEY"]      # PEM, newlines as \n

# --- Mailbox provider: 'gmail' or 'graph' ---
MAIL_PROVIDER = os.environ.get("MAIL_PROVIDER", "gmail")

# --- Gmail (OAuth refresh token flow for personal gmail.com) ---
GMAIL_CLIENT_ID = os.environ.get("GMAIL_CLIENT_ID", "")
GMAIL_CLIENT_SECRET = os.environ.get("GMAIL_CLIENT_SECRET", "")
GMAIL_REFRESH_TOKEN = os.environ.get("GMAIL_REFRESH_TOKEN", "")

# --- Microsoft Graph (mailbox polling) ---
MS_TENANT_ID = os.environ.get("MS_TENANT_ID", "")
MS_CLIENT_ID = os.environ.get("MS_CLIENT_ID", "")
MS_CLIENT_SECRET = os.environ.get("MS_CLIENT_SECRET", "")
MS_MAILBOX = os.environ.get("MS_MAILBOX", "")  # e.g. rfps@client.com

# Separate secret for the Cloud Scheduler -> /poll call. Falls back to
# WEBHOOK_SECRET so local testing stays simple.
POLL_SECRET = os.environ.get("POLL_SECRET", "")

# --- Shared secret between the email forwarder and this service ---
# The webhook caller must send header: X-Webhook-Secret: <value>
WEBHOOK_SECRET = os.environ.get("WEBHOOK_SECRET", "")

# --- Attachment classification ---
# Documents larger than these go to GCS + vector DB ingestion only and are
# never sent to the triage LLM.
TRIAGE_MAX_PAGES = int(os.environ.get("TRIAGE_MAX_PAGES", "30"))
TRIAGE_MAX_TEXT_CHARS = int(os.environ.get("TRIAGE_MAX_TEXT_CHARS", "60000"))
# GCS bucket for reference documents (spec books, plan sets).
GCS_BUCKET = os.environ.get("GCS_BUCKET", "")

# --- Scoring criteria ---
# Tweak these to match the client's go/no-go rules.
MIN_DEAL_VALUE = float(os.environ.get("MIN_DEAL_VALUE", "100000"))
MAX_RESPONSE_DAYS = int(os.environ.get("MAX_RESPONSE_DAYS", "14"))

# Capabilities the company can actually deliver. Comma-separated env var.
# The score rewards overlap between these and the RFP requirements.
COMPANY_CAPABILITIES = [
    c.strip().lower()
    for c in os.environ.get(
        "COMPANY_CAPABILITIES",
        "fire apparatus,ambulances,emergency vehicles,upfitting,service,maintenance",
    ).split(",")
    if c.strip()
]
