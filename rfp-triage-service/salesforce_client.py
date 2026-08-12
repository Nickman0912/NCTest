"""Salesforce REST client using OAuth 2.0 JWT bearer flow.

Server-to-server auth: no browser, no refresh token. The private key
signs a JWT that Salesforce exchanges for an access token. The matching
public certificate must be uploaded to the Connected App.
"""
import base64
import logging
import time

import jwt
import requests

import config

logger = logging.getLogger(__name__)

# Cache the token in module scope; Cloud Run instances live for many requests.
_token_cache = {"access_token": None, "instance_url": None, "expires_at": 0}


def _get_access_token() -> tuple[str, str]:
    if _token_cache["access_token"] and time.time() < _token_cache["expires_at"]:
        return _token_cache["access_token"], _token_cache["instance_url"]

    now = int(time.time())
    assertion = jwt.encode(
        {
            "iss": config.SF_CLIENT_ID,
            "sub": config.SF_USERNAME,
            "aud": config.SF_LOGIN_URL,
            "iat": now,
            "exp": now + 300,
        },
        config.SF_PRIVATE_KEY.replace("\\n", "\n"),
        algorithm="RS256",
    )

    resp = requests.post(
        f"{config.SF_LOGIN_URL}/services/oauth2/token",
        data={
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": assertion,
        },
        timeout=30,
    )
    if not resp.ok:
        # Salesforce returns a useful error_description in the body.
        raise RuntimeError(f"Salesforce OAuth failed: {resp.status_code} {resp.text}")
    body = resp.json()

    _token_cache.update(
        access_token=body["access_token"],
        instance_url=body["instance_url"],
        # Salesforce tokens last ~2h; refresh after 1h to be safe.
        expires_at=now + 3600,
    )
    return _token_cache["access_token"], _token_cache["instance_url"]


def create_rfp_record(payload: dict) -> dict:
    """POST to the RFPTriageService Apex REST endpoint."""
    token, instance_url = _get_access_token()
    resp = requests.post(
        f"{instance_url}/services/apexrest/rfp/triage",
        json=payload,
        headers={"Authorization": f"Bearer {token}"},
        timeout=30,
    )
    resp.raise_for_status()
    body = resp.json()
    if body.get("status") != "success":
        raise RuntimeError(f"Salesforce rejected the record: "
                           f"{body.get('errorMessage')}")
    logger.info("Created RFP record %s", body["rfpId"])
    return body
