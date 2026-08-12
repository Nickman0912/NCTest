"""Gmail polling client.

For a personal gmail.com account we can't use a service account (that
requires Workspace domain-wide delegation), so this uses an OAuth refresh
token minted once via the Google OAuth playground / a one-time consent
flow. Scopes are read + modify (to mark messages read and label them).

At a client on Google Workspace, swap this for a service account with
domain-wide delegation - the API calls below stay identical, only the
credential acquisition changes.
"""
import base64
import logging
import re
import time

import requests

import config

logger = logging.getLogger(__name__)

GMAIL = "https://gmail.googleapis.com/gmail/v1/users/me"

_token_cache = {"token": None, "expires_at": 0}

RFP_LABEL = "RFP Triage"


def _get_token() -> str:
    if _token_cache["token"] and time.time() < _token_cache["expires_at"]:
        return _token_cache["token"]

    resp = requests.post(
        "https://oauth2.googleapis.com/token",
        data={
            "client_id": config.GMAIL_CLIENT_ID,
            "client_secret": config.GMAIL_CLIENT_SECRET,
            "refresh_token": config.GMAIL_REFRESH_TOKEN,
            "grant_type": "refresh_token",
        },
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    _token_cache["token"] = body["access_token"]
    _token_cache["expires_at"] = time.time() + body.get("expires_in", 3600) - 300
    return _token_cache["token"]


def _headers() -> dict:
    return {"Authorization": f"Bearer {_get_token()}"}


def _label_id(name: str) -> str:
    """Get (or create) a Gmail label and return its ID."""
    resp = requests.get(f"{GMAIL}/labels", headers=_headers(), timeout=30)
    resp.raise_for_status()
    for label in resp.json().get("labels", []):
        if label["name"] == name:
            return label["id"]
    resp = requests.post(
        f"{GMAIL}/labels", headers=_headers(),
        json={"name": name, "labelListVisibility": "labelShow",
              "messageListVisibility": "show"},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()["id"]


def fetch_unread_with_attachments() -> list[dict]:
    """Return unread inbox messages that have attachments."""
    resp = requests.get(
        f"{GMAIL}/messages",
        headers=_headers(),
        params={"q": "is:unread in:inbox has:attachment", "maxResults": 25},
        timeout=30,
    )
    resp.raise_for_status()
    stubs = resp.json().get("messages", [])

    messages = []
    for stub in stubs:
        msg = requests.get(
            f"{GMAIL}/messages/{stub['id']}",
            headers=_headers(),
            params={"format": "full"},
            timeout=30,
        )
        msg.raise_for_status()
        payload = msg.json()["payload"]
        headers = {h["name"]: h["value"]
                   for h in payload.get("headers", [])}
        messages.append({
            "id": stub["id"],
            "subject": headers.get("Subject", ""),
            "from": headers.get("From", ""),
            "body": _extract_body(payload),
        })
    return messages


def _extract_body(payload: dict) -> str:
    """Extract plain-text body from a Gmail message payload, walking nested
    parts and preferring text/plain over text/html."""
    import html

    text_parts = []
    html_parts = []

    def walk(part):
        mime = part.get("mimeType", "")
        data = (part.get("body") or {}).get("data")
        if data:
            # Gmail uses URL-safe base64 without padding.
            data += "=" * (-len(data) % 4)
            decoded = base64.urlsafe_b64decode(data).decode(
                "utf-8", errors="replace")
            if mime == "text/plain":
                text_parts.append(decoded)
            elif mime == "text/html":
                html_parts.append(decoded)
        for sub in part.get("parts", []):
            walk(sub)

    walk(payload)
    if text_parts:
        return "\n".join(text_parts).strip()
    if html_parts:
        # Strip tags for a rough plain-text fallback.
        text = "\n".join(html_parts)
        text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
        text = re.sub(r"</p>\s*", "\n", text, flags=re.IGNORECASE)
        text = re.sub(r"<[^>]+>", "", text)
        return html.unescape(text).strip()
    return ""


def get_attachments(message_id: str) -> list[tuple[str, bytes]]:
    """Return [(filename, bytes)] for real attachments on a message."""
    resp = requests.get(
        f"{GMAIL}/messages/{message_id}", headers=_headers(),
        params={"format": "full"}, timeout=30,
    )
    resp.raise_for_status()
    payload = resp.json()["payload"]

    out = []

    def walk(part):
        filename = part.get("filename", "")
        attachment_id = (part.get("body") or {}).get("attachmentId")
        if filename and attachment_id:
            att = requests.get(
                f"{GMAIL}/messages/{message_id}/attachments/{attachment_id}",
                headers=_headers(), timeout=60,
            )
            att.raise_for_status()
            data = att.json()["data"]
            # Gmail uses URL-safe base64 without padding.
            data += "=" * (-len(data) % 4)
            out.append((filename, base64.urlsafe_b64decode(data)))
        for sub in part.get("parts", []):
            walk(sub)

    walk(payload)
    return out


def mark_processed(message_id: str, category: str) -> None:
    """Remove from inbox unread state and apply the triage label."""
    label = _label_id(f"{RFP_LABEL}/{category}")
    resp = requests.post(
        f"{GMAIL}/messages/{message_id}/modify",
        headers={**_headers(), "Content-Type": "application/json"},
        json={"removeLabelIds": ["UNREAD"], "addLabelIds": [label]},
        timeout=30,
    )
    resp.raise_for_status()
