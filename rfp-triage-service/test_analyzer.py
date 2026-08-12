"""Offline tests for scoring logic (no API calls)."""
import os
from datetime import date, timedelta

os.environ.setdefault("ANTHROPIC_API_KEY", "test")
os.environ.setdefault("SF_CLIENT_ID", "test")
os.environ.setdefault("SF_USERNAME", "test")
os.environ.setdefault("SF_PRIVATE_KEY", "test")

import analyzer  # noqa: E402


def _facts(**overrides):
    base = {
        "rfp_name": "Test RFP",
        "estimated_value": 250000,
        "due_date": (date.today() + timedelta(days=30)).isoformat(),
        "required_capabilities": ["fire apparatus", "service"],
        "incumbent_vendor": None,
        "summary": "A test RFP.",
    }
    base.update(overrides)
    return base


def test_strong_rfp_scores_high():
    result = analyzer.score_rfp(_facts())
    assert result["recommendation"] == "Pursue"
    assert result["score"] >= 70


def test_low_value_penalized():
    result = analyzer.score_rfp(_facts(estimated_value=5000))
    assert result["score"] < analyzer.score_rfp(_facts())["score"]


def test_past_deadline_kills_score():
    result = analyzer.score_rfp(_facts(due_date="2020-01-01"))
    assert result["recommendation"] == "Decline"


def test_no_capability_match_penalized():
    weak = analyzer.score_rfp(
        _facts(required_capabilities=["underwater basket weaving"]))
    strong = analyzer.score_rfp(_facts())
    # Zero capability coverage should drag the score well below a match.
    assert weak["score"] <= strong["score"] - 50


def test_incumbent_penalty():
    result = analyzer.score_rfp(_facts(incumbent_vendor="Pierce"))
    assert result["score"] < analyzer.score_rfp(_facts())["score"]
