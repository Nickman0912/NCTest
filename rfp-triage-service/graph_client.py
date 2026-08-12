"""Microsoft Graph client for polling an RFP mailbox.

Uses the client credentials flow (app-only auth): no signed-in user, the
service authenticates as itself with Mail.Read application scope. The app
registration should be locked to the single RFP mailbox via an Exchange
application access policy.
"""
import logging

import msal
import requests

import config

logger = logging.getLogger(__name__)

GRAPH = "https://graph.microsoft.com/v1.0"

_token_cache = {"token": None, "expires_at": 0}


def _get_token() -> str:
    import time
    if _token_cache["token"] and time.time() < _token_cache["expires_at"]:
        return _token_cache["token"]

    app = msal.ConfidentialClientApplication(
        config.MS_CLIENT_ID,
        authority=f"https://login.microsoftonline.com/{config.MS_TENANT_ID}",
        client_credential=config.MS_CLIENT_SECRET,
    )
    result = app.acquire_token_for_client(scopes=["https://graph.microsoft.com/.default"])
    if "access_token" not in result:
        raise RuntimeError(f"Graph auth failed: {result.get('error_description')}")
    _token_cache["token"] = result["access_token"]
    _token_cache["expires_at"] = time.time() + result.get("expires_in", 3600) - 300
    return _token_cache["token"]


def _headers() -> dict:
    return {"Authorization": f"Bearer {_get_token()}"}


def fetch_unread_with_attachments() -> list[dict]:
    """Return unread messages in the RFP mailbox that have attachments."""
    resp = requests.get(
        f"{GRAPH}/users/{config.MS_MAILBOX}/messages",
        headers=_headers(),
        params={
            "$filter": "isRead eq false and hasAttachments eq true",
            "$select": "id,subject,from,receivedDateTime,body",
            "$top": "25",
        },
        timeout=30,
    )
    resp.raise_for_status()
    messages = resp.json().get("value", [])
    for msg in messages:
        body = (msg.get("body") or {}).get("content", "")
        content_type = (msg.get("body") or {}).get("contentType", "")
        msg["body"] = _strip_html(body) if content_type == "html" else body
    return messages


def _strip_html(text: str) -> str:
    """Rough HTML-to-text conversion for Graph's default HTML bodies."""
    import html
    import re

    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"</p>\s*", "\n", text, flags=re.IGNORECASE)
    text = re.sub(r"<[^>]+>", "", text)
    return html.unescape(text).strip()


def get_attachments(message_id: str) -> list[tuple[str, bytes]]:
    """Return [(filename, bytes)] for file attachments on a message."""
    resp = requests.get(
        f"{GRAPH}/users/{config.MS_MAILBOX}/messages/{message_id}/attachments",
        headers=_headers(),
        params={"$select": "name,contentType,contentBytes"},
        timeout=60,
    )
    resp.raise_for_status()
    out = []
    for att in resp.json().get("value", []):
        # itemAttachment (attached emails) have no contentBytes; skip them.
        if att.get("@odata.type") == "#microsoft.graph.fileAttachment":
            import base64
            out.append((att["name"], base64.b64decode(att["contentBytes"])))
    return out


def mark_processed(message_id: str, category: str) -> None:
    """Mark read and stamp a category so reps can filter in Outlook."""
    resp = requests.patch(
        f"{GRAPH}/users/{config.MS_MAILBOX}/messages/{message_id}",
        headers={**_headers(), "Content-Type": "application/json"},
        json={"isRead": True, "categories": [category]},
        timeout=30,
    )
    resp.raise_for_status()
