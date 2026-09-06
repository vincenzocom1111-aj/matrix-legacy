"""
Builds the structured prompt sent to Gemma for course content generation.
"""
from typing import Optional

# ──────────────────────────────────────────────────────────────────────────────
# Image-token instruction — injected verbatim into every generation prompt.
# ──────────────────────────────────────────────────────────────────────────────

_IMAGE_TOKEN_INSTRUCTION = """\
When structuring the content, if the source material references a figure,
diagram, circuit, or graph (e.g. "Figure 1.1", "Fig 2.3", "Circuit 3.1",
"Diagram 4.2"), insert an inline token at that exact point in this exact format:

[img:{id}|{short_title}|{description of what it should depict, based on the surrounding text}]

Example:
[img:fig1.1|FM receiver block diagram|Shows antenna, RF amplifier, mixer, IF amplifier, detector, and audio amplifier stages in sequence]

Rules:
- Use ONLY this token format for figure references. Do NOT describe the figure in prose instead.
- Do NOT skip any figure/diagram/circuit reference found in the source text.
- Keep {id} consistent with the source numbering (e.g. "fig1.1" for "Figure 1.1").
- If the same figure is referenced again later in the text, reuse the same {id}.
- Do NOT generate fake figure references that are not in the source material.\
"""


# ──────────────────────────────────────────────────────────────────────────────
# Default format template — used when admin doesn't supply one
# ──────────────────────────────────────────────────────────────────────────────

DEFAULT_FORMAT_TEMPLATE = """\
Structure and format the provided source material directly:
- Carefully read the provided source files and organize the material into clear, well-structured sections with descriptive headings.
- Strictly adhere to the facts, concepts, technical details, formulas, and explanations present in the source files.
- DO NOT make any assumptions, extrapolate, or invent information not explicitly supported by the source text.
- Highlight key terms and important definitions using **bold**.
- Retain all equations, data, and technical specifications exactly as provided in the source files.
- Follow any specific formatting or structural requirements specified in the format instructions.\
"""


# ──────────────────────────────────────────────────────────────────────────────
# Prompt builder
# ──────────────────────────────────────────────────────────────────────────────

def build_prompt(
    extracted_text: str,
    format_template: Optional[str] = None,
    pyq_topics: Optional[list[str]] = None,
    mode: str = "create",
    existing_content: Optional[str] = None,
) -> str:
    """
    Assembles the full prompt string from components.

    Args:
        extracted_text:   Text extracted from source files (PDF/DOCX/image).
        format_template:  Admin-supplied format instructions. Falls back to DEFAULT.
        pyq_topics:       Optional list of previous-year-question topic strings.
        mode:             "create" (from scratch) or "enhance" (extend existing).
        existing_content: Current module content, only used in "enhance" mode.
    """
    template = (format_template or "").strip() or DEFAULT_FORMAT_TEMPLATE
    parts: list[str] = []

    # ── Role + task description ────────────────────────────────────────────────
    if mode == "enhance" and existing_content and existing_content.strip():
        parts.append(
            "You are an AI document structuring assistant.\n"
            "Your task is to ENHANCE and UPDATE the existing document content using ONLY the new "
            "source material provided below.\n"
            "Strictly follow the provided materials: do NOT make any assumptions or invent facts not found in the source files.\n"
            "Preserve existing valid structure and explanations, and incorporate new content from the source faithfully.\n"
            "Do NOT re-generate [img:...] tokens that already exist in the existing content — "
            "only add NEW tokens for figures referenced in the new source material.\n"
        )
        parts.append(f"=== EXISTING CONTENT ===\n{existing_content.strip()}\n")
    else:
        parts.append(
            "You are an AI document structuring assistant.\n"
            "Your task is to take the provided source material and organize/structure it cleanly "
            "based strictly on the text provided, adhering to the format requirements below.\n"
            "CRITICAL: Do NOT make assumptions, guess, or introduce outside knowledge. "
            "Rely entirely on the provided source files and do the requested structuring task.\n"
        )

    # ── Format instructions ────────────────────────────────────────────────────
    parts.append(f"=== FORMAT REQUIREMENTS ===\n{template}\n")

    # ── PYQ topics (optional) ──────────────────────────────────────────────────
    if pyq_topics:
        topic_list = "\n".join(f"  - {t}" for t in pyq_topics)
        parts.append(
            f"=== PREVIOUS YEAR QUESTION TOPICS ===\n"
            f"Ensure each of these topics from the source material is thoroughly covered:\n"
            f"{topic_list}\n"
        )

    # ── Image token instruction ────────────────────────────────────────────────
    parts.append(f"=== IMAGE TOKEN INSTRUCTIONS ===\n{_IMAGE_TOKEN_INSTRUCTION}\n")

    # ── Source material ────────────────────────────────────────────────────────
    parts.append(f"=== SOURCE MATERIAL ===\n{extracted_text.strip()}\n")

    # ── Generation trigger ─────────────────────────────────────────────────────
    action = "enhanced" if mode == "enhance" else "structured"
    parts.append(
        f"Now produce the complete {action} content strictly following all format requirements "
        f"and source material above. Do NOT make any assumptions outside the provided files. "
        f"Begin directly with the structured output:"
    )

    return "\n\n".join(parts)
