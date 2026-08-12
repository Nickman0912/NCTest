"""LLM analysis of RFP text.

Two-step approach:
1. The LLM extracts structured facts from the document (it never decides
   the score - LLMs are inconsistent at that).
2. Deterministic Python code computes the pursuit score from those facts,
   so the same RFP always gets the same score.
"""
import json
import logging
from datetime import date

import anthropic

import config

logger = logging.getLogger(__name__)

# JSON schema for the extracted facts. OpenRouter (OpenAI-style) uses
# this directly as a response_format; Anthropic gets it wrapped as a tool.
EXTRACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "rfp_name": {"type": "string",
                     "description": "Title or short name of the RFP"},
        "issuing_organization": {"type": ["string", "null"]},
        "due_date": {"type": ["string", "null"],
                     "description": "Submission deadline, yyyy-MM-dd, or null"},
        "estimated_value": {"type": ["number", "null"],
                            "description": "Estimated contract value in USD, or null"},
        "geography": {"type": ["string", "null"],
                      "description": "Where the work is performed"},
        "required_capabilities": {"type": "array", "items": {"type": "string"},
                                  "description": "Capabilities/products the RFP requires"},
        "incumbent_vendor": {"type": ["string", "null"]},
        "decision_timeline": {"type": ["string", "null"],
                              "description": "When the buyer says they'll decide"},
        "summary": {"type": "string",
                    "description": "2-3 sentence plain-English summary of the opportunity"},
        "portal_url": {"type": ["string", "null"],
                       "description": (
                           "URL to the contractor portal or document download "
                           "page mentioned in the email body (e.g. a "
                           "BuildingConnected / bid-portal link), or null if "
                           "none is present."
                       )},
        "extraction_confidence": {
            "type": "integer",
            "description": (
                "0-100: how confident are you that the extracted values are "
                "accurate and complete? Deduct for illegible pages, missing "
                "key facts (no due date, no value), ambiguous wording, or "
                "poor scan quality. 90+ = clean document, all key facts present."
            ),
        },
    },
    # OpenAI strict mode requires every property listed here; nullable
    # fields are expressed via ["string", "null"] types above.
    "required": [
        "rfp_name", "issuing_organization", "due_date", "estimated_value",
        "geography", "required_capabilities", "incumbent_vendor",
        "decision_timeline", "summary", "portal_url", "extraction_confidence",
    ],
    "additionalProperties": False,
}

EXTRACTION_TOOL = {
    "name": "record_rfp_details",
    "description": "Record the key characteristics extracted from an RFP document.",
    "input_schema": EXTRACTION_SCHEMA,
}

PROMPT = (
    "Extract the key characteristics from this RFP document. "
    "If a value isn't stated, use null rather than guessing.\n\n"
    "--- RFP DOCUMENT ---\n{text}"
)

VISION_PROMPT = (
    "These images are scanned pages of an RFP document. Read them carefully "
    "and extract the key characteristics. If a value isn't stated or isn't "
    "legible, use null rather than guessing - illegibility should also lower "
    "your extraction_confidence score."
)


def analyze_rfp(extraction) -> dict:
    """Extract structured facts from an ExtractionResult (text or page
    images) via the configured provider."""
    if config.LLM_PROVIDER == "anthropic":
        return _analyze_anthropic(extraction)
    return _analyze_openrouter(extraction)


def _text_prompt(extraction) -> str:
    # Truncate absurdly long documents; ~100k chars is far past typical RFPs.
    return PROMPT.format(text=extraction.text[:100000])


def _confidence_floor(facts: dict) -> int:
    """Deterministic floor for reliability: penalize for missing key fields
    so a model can't claim 95% confidence while returning nulls."""
    key_fields = ["issuing_organization", "due_date", "estimated_value",
                  "geography", "decision_timeline"]
    missing = sum(1 for f in key_fields if not facts.get(f))
    return max(20, 100 - missing * 15)


def _analyze_openrouter(extraction) -> dict:
    """OpenRouter speaks the OpenAI API; json_schema response_format
    guarantees the shape on supported models."""
    from openai import OpenAI

    client = OpenAI(
        base_url="https://openrouter.ai/api/v1",
        api_key=config.OPENROUTER_API_KEY,
    )

    if extraction.method == "Vision":
        model = config.VISION_MODEL
        content = [{"type": "text", "text": VISION_PROMPT}]
        content += [
            {"type": "image_url",
             "image_url": {"url": f"data:image/png;base64,{img}"}}
            for img in extraction.page_images
        ]
    else:
        model = config.EXTRACTION_MODEL
        content = [{"type": "text", "text": _text_prompt(extraction)}]

    resp = client.chat.completions.create(
        model=model,
        max_tokens=2000,
        messages=[{"role": "user", "content": content}],
        response_format={
            "type": "json_schema",
            "json_schema": {
                "name": "rfp_extraction",
                "strict": True,
                "schema": EXTRACTION_SCHEMA,
            },
        },
    )
    facts = json.loads(resp.choices[0].message.content)
    # Model self-assessment, capped by the deterministic floor.
    self_score = facts.get("extraction_confidence") or 50
    facts["extraction_confidence"] = min(self_score, _confidence_floor(facts))
    return facts


def _analyze_anthropic(extraction) -> dict:
    client = anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)

    if extraction.method == "Vision":
        content = [
            {"type": "image",
             "source": {"type": "base64", "media_type": "image/png",
                        "data": img}}
            for img in extraction.page_images
        ]
        content.append({"type": "text", "text": VISION_PROMPT})
    else:
        content = [{"type": "text", "text": _text_prompt(extraction)}]

    message = client.messages.create(
        model=config.ANTHROPIC_MODEL,
        max_tokens=2000,
        tools=[EXTRACTION_TOOL],
        tool_choice={"type": "tool", "name": "record_rfp_details"},
        messages=[{"role": "user", "content": content}],
    )
    for block in message.content:
        if block.type == "tool_use":
            facts = block.input
            self_score = facts.get("extraction_confidence") or 50
            facts["extraction_confidence"] = min(self_score,
                                                 _confidence_floor(facts))
            return facts
    raise RuntimeError("Model did not return structured output")


SUMMARY_PROMPT = (
    "You are helping a construction estimator review bid documents for an "
    "RFP. Using ONLY the excerpts below, write a concise project summary and "
    "a pursue/decline recommendation. Structure it as:\n"
    "- Project overview (what's being built/bought, for whom, where)\n"
    "- Key dates (submission deadline, decision timeline, delivery)\n"
    "- Scope & requirements (capabilities, products, certifications)\n"
    "- Commercial terms (estimated value, liquidated damages, insurance, "
    "bonding)\n"
    "- Risks & gaps (anything missing, ambiguous, or concerning)\n"
    "- Recommendation (Pursue / Review / Decline) with 1-2 sentence rationale\n\n"
    "If a fact isn't in the excerpts, say so plainly - do not guess.\n\n"
    "EXCERPTS:\n{context}"
)


def summarize_rfp(context: str) -> str:
    """Generate a project summary + recommendation from retrieved RAG chunks.
    Plain-text response (no JSON schema) - this is a narrative, not extraction."""
    prompt = SUMMARY_PROMPT.format(context=context[:60000])

    if config.LLM_PROVIDER == "anthropic":
        client = anthropic.Anthropic(api_key=config.ANTHROPIC_API_KEY)
        message = client.messages.create(
            model=config.GENERATION_MODEL,
            max_tokens=2000,
            messages=[{"role": "user", "content": prompt}],
        )
        return "".join(b.text for b in message.content if b.type == "text")

    from openai import OpenAI
    client = OpenAI(base_url="https://openrouter.ai/api/v1",
                    api_key=config.OPENROUTER_API_KEY)
    resp = client.chat.completions.create(
        model=config.GENERATION_MODEL,
        max_tokens=2000,
        messages=[{"role": "user", "content": prompt}],
    )
    return resp.choices[0].message.content


def score_rfp(facts: dict) -> dict:
    """Deterministic scoring. Returns {score, recommendation, notes}."""
    score = 50  # start neutral, adjust
    reasons = []

    value = facts.get("estimated_value")
    if value is not None:
        if value >= config.MIN_DEAL_VALUE:
            score += 20
            reasons.append(f"Estimated value ${value:,.0f} meets the "
                           f"${config.MIN_DEAL_VALUE:,.0f} threshold (+20)")
        else:
            score -= 20
            reasons.append(f"Estimated value ${value:,.0f} is below the "
                           f"${config.MIN_DEAL_VALUE:,.0f} threshold (-20)")
    else:
        reasons.append("No estimated value found (no adjustment)")

    due = facts.get("due_date")
    if due:
        try:
            days_left = (date.fromisoformat(due) - date.today()).days
            if days_left < 0:
                # Expired RFP is an auto-decline regardless of other factors.
                return {"score": 0, "recommendation": "Decline",
                        "notes": facts.get("summary", "") +
                        f"\n\nScoring rationale:\n- Deadline {due} has already "
                        "passed - auto-decline"}
            elif days_left < config.MAX_RESPONSE_DAYS:
                score -= 20
                reasons.append(f"Only {days_left} days to respond "
                               f"(< {config.MAX_RESPONSE_DAYS}) (-20)")
            else:
                score += 10
                reasons.append(f"{days_left} days to respond is workable (+10)")
        except ValueError:
            reasons.append(f"Unparseable due date '{due}' (no adjustment)")

    required = [c.lower() for c in facts.get("required_capabilities", [])]
    if required:
        matches = [c for c in required
                   if any(cap in c or c in cap for cap in config.COMPANY_CAPABILITIES)]
        coverage = len(matches) / len(required)
        if coverage >= 0.7:
            score += 20
            reasons.append(f"Strong capability match "
                           f"({len(matches)}/{len(required)} covered) (+20)")
        elif coverage >= 0.4:
            score += 5
            reasons.append(f"Partial capability match "
                           f"({len(matches)}/{len(required)} covered) (+5)")
        else:
            score -= 30
            reasons.append(f"Weak capability match "
                           f"({len(matches)}/{len(required)} covered) (-30)")

    if facts.get("incumbent_vendor"):
        score -= 10
        reasons.append(f"Incumbent ({facts['incumbent_vendor']}) likely has "
                       f"inside track (-10)")

    score = max(0, min(100, score))
    recommendation = ("Pursue" if score >= 70
                      else "Review" if score >= 40 else "Decline")

    notes = facts.get("summary", "") + "\n\nScoring rationale:\n" + \
        "\n".join(f"- {r}" for r in reasons)
    return {"score": score, "recommendation": recommendation, "notes": notes}
