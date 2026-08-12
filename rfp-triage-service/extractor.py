"""Pull content out of RFP attachments (PDF / DOCX / TXT).

Returns an ExtractionResult telling the caller whether usable text came
out (method="Text") or the document looks like a scan and the caller
should send page images to a vision model (method="Vision").
"""
import base64
import io
import logging
from dataclasses import dataclass, field

logger = logging.getLogger(__name__)

# Below this many characters from a whole PDF, assume it's a scan.
MIN_TEXT_CHARS = 50
# Cap pages sent to the vision model; keeps cost/latency bounded.
MAX_VISION_PAGES = 15


@dataclass
class ExtractionResult:
    method: str                       # "Text" or "Vision"
    text: str = ""                    # populated when method == "Text"
    page_images: list[str] = field(default_factory=list)  # base64 PNGs


def pdf_page_count(file_bytes: bytes) -> int:
    """Return the number of pages in a PDF without extracting text."""
    from pypdf import PdfReader
    return len(PdfReader(io.BytesIO(file_bytes)).pages)


def extract(file_bytes: bytes, filename: str) -> ExtractionResult:
    lower = filename.lower()

    if lower.endswith(".pdf"):
        return _from_pdf(file_bytes)
    if lower.endswith(".docx"):
        return ExtractionResult(method="Text", text=_from_docx(file_bytes))
    if lower.endswith((".txt", ".text", ".md")):
        return ExtractionResult(
            method="Text", text=file_bytes.decode("utf-8", errors="replace"))

    raise ValueError(f"Unsupported file type: {filename}")


def _from_pdf(file_bytes: bytes) -> ExtractionResult:
    from pypdf import PdfReader

    reader = PdfReader(io.BytesIO(file_bytes))
    pages = []
    for i, page in enumerate(reader.pages):
        try:
            pages.append(page.extract_text() or "")
        except Exception:
            logger.warning("Failed to extract page %s", i)
    text = "\n".join(pages).strip()

    if len(text) >= MIN_TEXT_CHARS:
        return ExtractionResult(method="Text", text=text)

    logger.info("Only %d chars extracted - treating as scanned document",
                len(text))
    return ExtractionResult(method="Vision",
                            page_images=_render_pages(file_bytes))


def _render_pages(file_bytes: bytes) -> list[str]:
    """Render PDF pages to base64 PNGs for the vision model."""
    import pypdfium2 as pdfium

    pdf = pdfium.PdfDocument(file_bytes)
    images = []
    for i in range(min(len(pdf), MAX_VISION_PAGES)):
        # 150 DPI is plenty for text legibility and keeps payloads small.
        bitmap = pdf[i].render(scale=150 / 72)
        img = bitmap.to_pil()
        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True)
        images.append(base64.b64encode(buf.getvalue()).decode())
    if len(pdf) > MAX_VISION_PAGES:
        logger.warning("PDF has %d pages; only first %d sent to vision model",
                       len(pdf), MAX_VISION_PAGES)
    pdf.close()
    return images


def _from_docx(file_bytes: bytes) -> str:
    import docx

    doc = docx.Document(io.BytesIO(file_bytes))
    return "\n".join(p.text for p in doc.paragraphs).strip()
