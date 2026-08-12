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
# Any OpenRouter model slug. Mini is dirt cheap and fine for extraction;
# anthropic/claude-haiku or google/gemini-2.5-flash are good alternatives.
OPENROUTER_MODEL = os.environ.get("OPENROUTER_MODEL", "openai/gpt-4o-mini")
# Used for scanned/image-only documents. gpt-4o-mini handles vision, but a
# stronger model earns its keep on messy scans.
VISION_MODEL = os.environ.get("VISION_MODEL", "openai/gpt-4o-mini")

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
