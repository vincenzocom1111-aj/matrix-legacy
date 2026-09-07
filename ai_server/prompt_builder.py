"""
Builds the structured prompt sent to Gemma for course content generation,
verification, critique, and refinement.
"""
import re
from typing import Optional, Tuple

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


# ──────────────────────────────────────────────────────────────────────────────
# Deterministic Structural Checks (Token preservation, Headings, Bold formatting)
# ──────────────────────────────────────────────────────────────────────────────

_TOKEN_REGEX = re.compile(r'\[img:([^\|\]]+)\|([^\|\]]+)\|([^\]]+)\]', re.IGNORECASE)
_HEADING_REGEX = re.compile(r'^#{1,6}\s+\S+', re.MULTILINE)
_BOLD_REGEX = re.compile(r'\*\*[^*]+\*\*')
_SOURCE_FIGURE_REGEX = re.compile(r'\b(?:fig(?:ure)?\.?|circuit|diagram)\s+([0-9]+(?:\.[0-9]+)?)', re.IGNORECASE)

def check_structure(source_text: str, generated_text: str) -> dict:
    """
    Deterministically evaluates mechanical/structural correctness without calling LLM:
    - Checks for headings (markdown #).
    - Checks for bold keywords (**term**).
    - Checks for [img:...] tokens if source mentions figures/diagrams.

    Returns dict with penalty (0-20), pass status, and notes.
    """
    notes = []
    penalty = 0

    has_headings = bool(_HEADING_REGEX.search(generated_text))
    if not has_headings:
        penalty += 5
        notes.append("Missing markdown section headings (# or ##).")

    has_bold = bool(_BOLD_REGEX.search(generated_text))
    if not has_bold:
        penalty += 5
        notes.append("Missing bolded key terms (**term**).")

    source_fig_refs = set(m.group(0).lower() for m in _SOURCE_FIGURE_REGEX.finditer(source_text))
    gen_tokens = _TOKEN_REGEX.findall(generated_text)

    if source_fig_refs and not gen_tokens:
        penalty += 10
        notes.append(f"Source references figures ({len(source_fig_refs)} found), but generated content contains no [img:...] tokens.")

    return {
        "penalty": penalty,
        "notes": notes,
        "has_headings": has_headings,
        "has_bold": has_bold,
        "tokens_count": len(gen_tokens),
    }


# ──────────────────────────────────────────────────────────────────────────────
# Verification Prompt & Refinement Prompt
# ──────────────────────────────────────────────────────────────────────────────

def build_verification_prompt(
    source_context: str,
    generated_content: str,
    pyq_topics: Optional[list[str]] = None,
) -> str:
    """
    Builds a prompt asking Gemma to audit the generated content against the source context
    for assumptions, hallucinations, and missing topics.
    """
    pyq_section = ""
    if pyq_topics:
        pyq_section = (
            "\n=== MANDATORY PREVIOUS YEAR QUESTION TOPICS ===\n" +
            "\n".join(f"- {t}" for t in pyq_topics) + "\n"
        )

    return f"""\
You are an expert curriculum and educational content quality auditor.
Your job is to objectively evaluate the GENERATED COURSE CONTENT against the ORIGINAL SOURCE CONTEXT.

Evaluation Criteria:
1. Grounding & Hallucinations / Assumptions: Does the generated content invent facts, make unsupported claims, or extrapolate beyond the provided source context? Deduct points for unsupported assumptions.
2. Completeness & Coverage: Did the generated content cover all essential technical definitions, concepts, formulas, and key topics found in the source context? Deduct points for skipped concepts.
{f"3. PYQ Coverage: Did the generated content adequately address all mandatory previous year question topics listed below?" if pyq_topics else ""}

CRITICAL INSTRUCTIONS:
- You must output an Efficiency Score as a percentage integer from 0 to 100.
  * 90-100: Highly accurate, complete coverage, no unsupported assumptions.
  * 70-89: Mostly accurate, but has minor missing topics, omissions, or assumptions.
  * <70: Major gaps, significant hallucinations/assumptions, or skipped key sections.
- Enclose the score strictly in <SCORE> tags, e.g. <SCORE>88</SCORE>
- Enclose your concise critique in <CRITIQUE> tags, listing:
  * Any assumptions/hallucinations detected.
  * Any missing key concepts or topics from the source.
  * Specific actionable recommendations to fix.

=== ORIGINAL SOURCE CONTEXT ===
{source_context.strip()}
{pyq_section}
=== GENERATED COURSE CONTENT ===
{generated_content.strip()}

Now evaluate and output your response with <SCORE> and <CRITIQUE> tags:
"""


def parse_verification_response(response_text: str) -> Tuple[Optional[int], str]:
    """
    Extracts (score, critique) from Gemma's response.
    Returns (None, reason) if parsing fails.
    """
    score_match = re.search(r'<SCORE>\s*(\d{1,3})\s*</SCORE>', response_text, re.IGNORECASE)
    critique_match = re.search(r'<CRITIQUE>(.*?)</CRITIQUE>', response_text, re.DOTALL | re.IGNORECASE)

    score: Optional[int] = None
    if score_match:
        try:
            val = int(score_match.group(1))
            if 0 <= val <= 100:
                score = val
        except ValueError:
            score = None

    critique = ""
    if critique_match:
        critique = critique_match.group(1).strip()
    elif not score_match:
        # Fallback if tags were omitted but content is present
        critique = response_text.strip()

    return score, critique


def build_refinement_prompt(
    source_context: str,
    previous_draft: str,
    critique: str,
    format_template: Optional[str] = None,
    pyq_topics: Optional[list[str]] = None,
) -> str:
    """
    Builds a prompt instructing Gemma to correct previous issues based on the critique,
    filling in missing content and removing assumptions.
    """
    template = (format_template or "").strip() or DEFAULT_FORMAT_TEMPLATE
    pyq_section = ""
    if pyq_topics:
        pyq_section = (
            f"\n=== MANDATORY PYQ TOPICS ===\n" +
            "\n".join(f"- {t}" for t in pyq_topics) + "\n"
        )

    return f"""\
You are an expert course writer and editor.
Your previous draft of the course content received a quality audit critique indicating missing content or unsupported assumptions.
You must now produce a REFINED, COMPLETE, AND CORRECTED version of the course content.

=== AUDIT CRITIQUE & REQUIRED FIXES ===
{critique.strip()}

=== FORMAT REQUIREMENTS ===
{template}
{pyq_section}
=== IMAGE TOKEN INSTRUCTIONS ===
{_IMAGE_TOKEN_INSTRUCTION}

=== ORIGINAL SOURCE CONTEXT ===
{source_context.strip()}

=== PREVIOUS DRAFT ===
{previous_draft.strip()}

CRITICAL INSTRUCTIONS:
- Fix every issue noted in the critique.
- Eliminate any unsupported assumptions or hallucinated details not backed by the original source context.
- Fully include any missing concepts, equations, definitions, or PYQ topics from the source context.
- Keep all valid [img:...] tokens and retain clear markdown structure with headings (#) and bold terms (**term**).
- Output ONLY the complete refined course content from start to finish. Begin immediately:
"""
