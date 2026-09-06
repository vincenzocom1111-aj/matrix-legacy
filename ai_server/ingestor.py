"""
Text extraction from PDF, DOCX, and image files.

PDF strategy:
  1. Try PyMuPDF text layer extraction (fast, accurate if PDF has a real text layer).
  2. If a page yields fewer than 50 characters (scanned/image-only page),
     render that page to a PNG at 200 DPI and run Tesseract OCR on it.

DOCX: python-docx, always has a text layer.
Image files (jpg/png/bmp/tiff): Tesseract directly.
"""

import io
import os
from typing import Callable, Optional

# ──────────────────────────────────────────────────────────────────────────────
# Tesseract path initialization (Windows safe)
# ──────────────────────────────────────────────────────────────────────────────

def init_tesseract() -> bool:
    """Configures pytesseract with explicit Windows installation path if found."""
    try:
        import pytesseract
        candidates = [
            r"C:\Program Files\Tesseract-OCR\tesseract.exe",
            r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
            os.path.expandvars(r"%LOCALAPPDATA%\Programs\Tesseract-OCR\tesseract.exe"),
        ]
        for c in candidates:
            if os.path.isfile(c):
                pytesseract.pytesseract.tesseract_cmd = c
                return True
        return False
    except ImportError:
        return False

init_tesseract()


# ──────────────────────────────────────────────────────────────────────────────
# OCR helper
# ──────────────────────────────────────────────────────────────────────────────

def _ocr_bytes(image_bytes: bytes, filename_hint: str = "") -> str:
    """Run Tesseract OCR on raw image bytes. Returns extracted text."""
    try:
        init_tesseract()
        import pytesseract
        from PIL import Image
        img = Image.open(io.BytesIO(image_bytes))
        return pytesseract.image_to_string(img)
    except ImportError:
        return (
            "[OCR skipped: pytesseract / Pillow not installed. "
            "Install Tesseract and run: pip install pytesseract pillow]"
        )
    except Exception as e:
        return f"[OCR failed for {filename_hint}: {e}]"


# ──────────────────────────────────────────────────────────────────────────────
# PDF
# ──────────────────────────────────────────────────────────────────────────────

def extract_text_from_pdf(
    file_bytes: bytes,
    on_progress: Optional[Callable[[str], None]] = None,
) -> str:
    """
    Extract text from a PDF. Falls back to Tesseract OCR per-page when the
    text layer is missing or near-empty (< 50 chars after stripping whitespace).
    """
    try:
        import fitz  # PyMuPDF
    except ImportError:
        return "[PDF extraction failed: PyMuPDF not installed. Run: pip install pymupdf]"

    try:
        doc = fitz.open(stream=file_bytes, filetype="pdf")
    except Exception as e:
        return f"[Could not open PDF: {e}]"

    total_pages = len(doc)
    page_texts: list[str] = []
    for page_num, page in enumerate(doc, start=1):
        if on_progress:
            on_progress(f"Reading page {page_num} of {total_pages}...")
        text = page.get_text().strip()
        if len(text) < 50:
            if on_progress:
                on_progress(f"Page {page_num} of {total_pages} is image-only, running OCR...")
            # Render page to image and OCR
            pix = page.get_pixmap(dpi=200)
            img_bytes = pix.tobytes("png")
            ocr_text = _ocr_bytes(img_bytes, filename_hint=f"page {page_num}")
            page_texts.append(f"[Page {page_num} — OCR]\n{ocr_text.strip()}")
        else:
            page_texts.append(f"[Page {page_num}]\n{text}")

    return "\n\n".join(page_texts)


# ──────────────────────────────────────────────────────────────────────────────
# DOCX
# ──────────────────────────────────────────────────────────────────────────────

def extract_text_from_docx(file_bytes: bytes) -> str:
    """Extract plain text from a DOCX file using python-docx."""
    try:
        import docx
    except ImportError:
        return "[DOCX extraction failed: python-docx not installed. Run: pip install python-docx]"

    try:
        doc = docx.Document(io.BytesIO(file_bytes))
        paragraphs = [p.text for p in doc.paragraphs if p.text.strip()]
        return "\n".join(paragraphs)
    except Exception as e:
        return f"[Could not read DOCX: {e}]"


# ──────────────────────────────────────────────────────────────────────────────
# Image files (standalone JPG/PNG/etc.)
# ──────────────────────────────────────────────────────────────────────────────

def extract_text_from_image(file_bytes: bytes, filename: str = "") -> str:
    """Run Tesseract OCR on a standalone image file."""
    return _ocr_bytes(file_bytes, filename_hint=filename)
