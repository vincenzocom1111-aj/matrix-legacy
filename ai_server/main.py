"""
MatrixF AI Server — FastAPI entry point.

Endpoints:
  GET  /health              — Checks Ollama + Tesseract availability.
  POST /ingest              — Starts a generation job (returns job_id immediately).
  GET  /status/{job_id}     — Polls job status and retrieves result when done.

All endpoints (except /health) require the X-API-Key header to match
the AI_SERVER_API_KEY environment variable.

Start with:
  uvicorn main:app --host 0.0.0.0 --port 8000 --reload
"""

from __future__ import annotations

import json
import logging
from typing import Annotated, Optional

from fastapi import BackgroundTasks, Depends, FastAPI, Form, Header, HTTPException, UploadFile, File
from fastapi.middleware.cors import CORSMiddleware

import ingestor
import job_store
import ollama_client
import prompt_builder
import course_agent
from config import API_KEY, OLLAMA_MODEL

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("matrixf_ai")

app = FastAPI(
    title="MatrixF AI Server",
    description="Local AI generation server for the matrixf education platform.",
    version="1.0.0",
)

# Allow the Flutter app (any local origin) to call this server.
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# ──────────────────────────────────────────────────────────────────────────────
# Auth dependency
# ──────────────────────────────────────────────────────────────────────────────

def _verify_key(x_api_key: Annotated[str, Header()] = "") -> None:
    if x_api_key != API_KEY:
        raise HTTPException(status_code=401, detail="Invalid or missing X-API-Key header.")


KeyDep = Annotated[None, Depends(_verify_key)]


# ──────────────────────────────────────────────────────────────────────────────
# Helper: check Tesseract
# ──────────────────────────────────────────────────────────────────────────────

def _tesseract_ok() -> bool:
    try:
        ingestor.init_tesseract()
        import pytesseract
        pytesseract.get_tesseract_version()
        return True
    except Exception:
        return False


# ──────────────────────────────────────────────────────────────────────────────
# GET /
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/")
def root():
    return {"status": "AI server running"}


# ──────────────────────────────────────────────────────────────────────────────
# GET /health
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/health")
async def health():
    """
    Quick check — does NOT require the API key so you can test reachability
    from a browser without extra headers.
    """
    ollama_ok = await ollama_client.check_health()
    tesseract_ok = _tesseract_ok()
    models = await ollama_client.list_models() if ollama_ok else []
    return {
        "status": "ready" if ollama_ok else "degraded",
        "ollama": "ok" if ollama_ok else "unreachable",
        "tesseract": "ok" if tesseract_ok else "not_found — OCR will be skipped",
        "configured_model": OLLAMA_MODEL,
        "available_models": models,
    }


# ──────────────────────────────────────────────────────────────────────────────
# POST /ingest
# ──────────────────────────────────────────────────────────────────────────────

@app.post("/ingest")
async def ingest(
    background_tasks: BackgroundTasks,
    _: KeyDep,
    files: list[UploadFile] = File(default=[]),
    raw_text: Optional[str] = Form(default=None),
    mode: str = Form(default="create"),
    format_template: Optional[str] = Form(default=None),
    pyq_topics: Optional[str] = Form(default=None),   # JSON array or comma-separated string
    existing_content: Optional[str] = Form(default=None),  # For "enhance" mode
):
    """
    Accepts source material (files + optional raw text) and starts a background
    generation job. Returns {job_id} immediately — poll /status/{job_id} for result.

    Form fields:
      files[]          — PDF, DOCX, JPG, PNG files (multipart, can be multiple)
      raw_text         — Optional plain text pasted by admin
      mode             — "create" | "enhance"
      format_template  — Admin-supplied formatting instructions
      pyq_topics       — JSON array of previous-year question topics, e.g. '["AM modulation","FM demodulation"]'
      existing_content — Current module content (only used when mode="enhance")
    """
    # Read all file bytes NOW, before handing off to background task
    file_data: list[dict] = []
    for f in files:
        if f.filename:
            content = await f.read()
            if content:
                file_data.append({"filename": f.filename, "bytes": content})

    # Parse pyq_topics — accept JSON array or comma-separated string
    pyq_list: Optional[list[str]] = None
    if pyq_topics and pyq_topics.strip():
        try:
            parsed = json.loads(pyq_topics)
            if isinstance(parsed, list):
                pyq_list = [str(t).strip() for t in parsed if str(t).strip()]
        except (json.JSONDecodeError, ValueError):
            pyq_list = [t.strip() for t in pyq_topics.split(",") if t.strip()]

    job = job_store.create_job()
    logger.info(f"Created job {job.job_id} — mode={mode}, files={[d['filename'] for d in file_data]}")

    background_tasks.add_task(
        _run_generation,
        job.job_id,
        file_data,
        raw_text,
        mode,
        format_template,
        pyq_list,
        existing_content,
    )

    return {"job_id": job.job_id}


# ──────────────────────────────────────────────────────────────────────────────
# POST /search-and-generate
# ──────────────────────────────────────────────────────────────────────────────

@app.post("/search-and-generate")
async def search_and_generate(
    background_tasks: BackgroundTasks,
    _: KeyDep,
    topic: str = Form(...),
    num_sources: int = Form(default=3),
):
    """
    Accepts a topic and starts a background job to search the web and generate a course section.
    Returns {job_id} immediately.
    """
    job = job_store.create_job()
    logger.info(f"Created job {job.job_id} — mode=search_and_generate, topic='{topic}'")

    background_tasks.add_task(
        _run_search_and_generation,
        job.job_id,
        topic,
        num_sources,
    )

    return {"job_id": job.job_id}


# ──────────────────────────────────────────────────────────────────────────────
# GET /status/{job_id}
# ──────────────────────────────────────────────────────────────────────────────

@app.get("/status/{job_id}")
async def status(job_id: str, _: KeyDep):
    """
    Poll the status of a generation job.

    Response:
      {
        "job_id": "...",
        "status": "pending" | "processing" | "done" | "failed",
        "stage": "extracting" | "analyzing" | "generating" | "done" | "failed",
        "stage_message": "...",
        "partial_text": "..."  <- live preview while generating
        "tokens_generated": 42,
        "result_text": "..." | null,
        "error_message": "..." | null
      }
    """
    job = job_store.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail=f"Job {job_id!r} not found.")
    return {
        "job_id": job.job_id,
        "status": job.status,
        "stage": job.stage,
        "stage_message": job.stage_message,
        "partial_text": job.partial_text,
        "tokens_generated": job.tokens_generated,
        "result_text": job.result_text,
        "error_message": job.error_message,
    }


# ──────────────────────────────────────────────────────────────────────────────
# Background task: run the full extraction → prompt → generation pipeline
# ──────────────────────────────────────────────────────────────────────────────

async def _run_generation(
    job_id: str,
    file_data: list[dict],
    raw_text: Optional[str],
    mode: str,
    format_template: Optional[str],
    pyq_topics: Optional[list[str]],
    existing_content: Optional[str],
) -> None:
    job_store.update_job(
        job_id,
        status="processing",
        stage="extracting",
        stage_message="Starting source extraction...",
    )
    logger.info(f"Job {job_id}: starting extraction")

    try:
        text_parts: list[str] = []

        # 1. Raw text (pasted by admin)
        if raw_text and raw_text.strip():
            text_parts.append(raw_text.strip())

        # 2. Uploaded files
        for item in file_data:
            filename: str = item.get("filename") or "unknown"
            file_bytes: bytes = item["bytes"]
            ext = filename.lower().rsplit(".", 1)[-1] if "." in filename else ""

            logger.info(f"Job {job_id}: extracting '{filename}' (type={ext})")
            job_store.update_job(
                job_id,
                stage="extracting",
                stage_message=f"Extracting '{filename}'...",
            )

            if ext == "pdf":
                def _pdf_prog(msg: str) -> None:
                    job_store.update_job(
                        job_id,
                        stage="extracting",
                        stage_message=f"{filename}: {msg}",
                    )
                text = ingestor.extract_text_from_pdf(file_bytes, on_progress=_pdf_prog)
            elif ext in ("docx", "doc"):
                text = ingestor.extract_text_from_docx(file_bytes)
            elif ext in ("jpg", "jpeg", "png", "bmp", "tiff", "tif", "webp"):
                job_store.update_job(
                    job_id,
                    stage="extracting",
                    stage_message=f"Running OCR on '{filename}'...",
                )
                text = ingestor.extract_text_from_image(file_bytes, filename)
            else:
                # Try UTF-8 decode as a last resort (plain .txt, etc.)
                text = file_bytes.decode("utf-8", errors="replace")

            if text.strip():
                text_parts.append(f"--- Source: {filename} ---\n{text}")

        if not text_parts:
            raise ValueError(
                "No text could be extracted from the provided files. "
                "Check that your files contain text or a legible image."
            )

        extracted_text = "\n\n".join(text_parts)
        logger.info(f"Job {job_id}: extracted {len(extracted_text)} chars — building prompt")
        job_store.update_job(
            job_id,
            stage="analyzing",
            stage_message=f"Extracted {len(extracted_text):,} chars. Preparing prompt...",
        )

        # 3. Build prompt
        prompt = prompt_builder.build_prompt(
            extracted_text=extracted_text,
            format_template=format_template,
            pyq_topics=pyq_topics,
            mode=mode,
            existing_content=existing_content,
        )

        logger.info(f"Job {job_id}: calling Ollama model={OLLAMA_MODEL} (streaming)")
        job_store.update_job(
            job_id,
            stage="analyzing",
            stage_message="Gemma 4 is analyzing prompt and thinking (CPU)...",
        )

        # 4. Call Ollama with streaming — each token updates partial_text in real-time
        first_token_seen = False

        async def _on_token(chunk: str) -> None:
            nonlocal first_token_seen
            if not first_token_seen:
                first_token_seen = True
                job_store.update_job(
                    job_id,
                    stage="generating",
                    stage_message="Gemma 4 is writing course content...",
                )
            job_store.append_token(job_id, chunk)

        result = await ollama_client.generate_streaming(prompt, on_token=_on_token)
        if not result.strip():
            raise ValueError("Ollama returned an empty response. Try a smaller file or check if the model is loaded.")

        logger.info(f"Job {job_id}: done — {len(result)} chars generated")
        job_store.update_job(
            job_id,
            status="done",
            stage="done",
            stage_message="Course generation complete!",
            result_text=result,
        )

    except Exception as exc:
        logger.error(f"Job {job_id} failed: {exc}", exc_info=True)
        job_store.update_job(
            job_id,
            status="failed",
            stage="failed",
            stage_message="Generation failed",
            error_message=str(exc),
        )


# ──────────────────────────────────────────────────────────────────────────────
# Background task: run web search and generation
# ──────────────────────────────────────────────────────────────────────────────

async def _run_search_and_generation(
    job_id: str,
    topic: str,
    num_sources: int,
) -> None:
    job_store.update_job(
        job_id,
        status="processing",
        stage="extracting",
        stage_message=f"Searching the web for '{topic}'...",
    )
    logger.info(f"Job {job_id}: starting web search for topic '{topic}'")

    try:
        # We run the blocking generate_course_section in a thread
        import asyncio
        loop = asyncio.get_running_loop()
        
        job_store.update_job(
            job_id,
            stage="generating",
            stage_message="Analyzing sources and generating course content...",
        )
        
        result = await loop.run_in_executor(
            None,
            lambda: course_agent.generate_course_section(
                topic=topic,
                num_sources=num_sources,
                model=OLLAMA_MODEL,
                on_status=lambda msg: job_store.update_job(
                    job_id,
                    stage="generating",
                    stage_message=msg,
                ),
            )
        )

        logger.info(f"Job {job_id}: done — {len(result)} chars generated from web search")
        job_store.update_job(
            job_id,
            status="done",
            stage="done",
            stage_message="Web search and course generation complete!",
            result_text=result,
            partial_text=result,
        )

    except Exception as exc:
        logger.error(f"Job {job_id} failed: {exc}", exc_info=True)
        job_store.update_job(
            job_id,
            status="failed",
            stage="failed",
            stage_message="Search/Generation failed",
            error_message=str(exc),
        )

