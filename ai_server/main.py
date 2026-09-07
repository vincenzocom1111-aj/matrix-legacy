@app.get("/status/{job_id}")
async def status(job_id: str, _: KeyDep):
    """
    Poll the status of a generation job.

    Response:
      {
        "job_id": "...",
        "status": "pending" | "processing" | "done" | "failed",
        "stage": "extracting" | "analyzing" | "generating" | "evaluating" | "refining" | "done" | "failed",
        "stage_message": "...",
        "partial_text": "..."  <- live preview while generating
        "tokens_generated": 42,
        "efficiency_score": 94 | null,
        "evaluation_feedback": "..." | null,
        "iteration": 1,
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
        "efficiency_score": job.efficiency_score,
        "evaluation_feedback": job.evaluation_feedback,
        "iteration": job.iteration,
        "result_text": job.result_text,
        "error_message": job.error_message,
    }


# ──────────────────────────────────────────────────────────────────────────────
# Helper: Evaluate draft content against source context with fallback
# ──────────────────────────────────────────────────────────────────────────────

async def _evaluate_and_score(
    source_context: str,
    draft_content: str,
    pyq_topics: Optional[list[str]] = None,
) -> tuple[int, str]:
    """
    Combines:
    1. Deterministic structural checks (headings, bold, figure tokens).
    2. LLM evaluation with Gemma for hallucinations/assumptions & completeness.
    Includes explicit fallback if Gemma does not emit valid <SCORE> or <CRITIQUE>.
    """
    # 1. Deterministic checks
    struct_result = prompt_builder.check_structure(source_context, draft_content)
    struct_penalty = struct_result["penalty"]
    struct_notes = struct_result["notes"]

    # 2. LLM evaluation prompt
    verif_prompt = prompt_builder.build_verification_prompt(
        source_context=source_context,
        generated_content=draft_content,
        pyq_topics=pyq_topics,
    )

    llm_score: Optional[int] = None
    critique = ""

    # Call LLM for verification (with 1 retry if parsing fails)
    for attempt in range(2):
        try:
            verif_response = await ollama_client.generate_streaming(
                verif_prompt,
                on_token=lambda _: None,
            )
            parsed_score, parsed_critique = prompt_builder.parse_verification_response(verif_response)
            if parsed_score is not None:
                llm_score = parsed_score
                critique = parsed_critique
                break
            else:
                logger.warning(f"Verification parse attempt {attempt+1} failed to find valid <SCORE> tags. Response: {verif_response[:200]}")
        except Exception as e:
            logger.warning(f"Verification call error on attempt {attempt+1}: {e}")

    # Explicit fallback if score is missing or parsing failed on both attempts
    if llm_score is None:
        logger.warning("Score tag missing after retry. Applying conservative fallback score of 75.")
        llm_score = 75
        if not critique:
            critique = "Automated audit note: LLM verification score tags were malformed. Applied conservative baseline score."

    # Incorporate structural findings
    final_score = max(0, min(100, llm_score - struct_penalty))
    all_critique_parts = []
    if struct_notes:
        all_critique_parts.append("Structural issues: " + "; ".join(struct_notes))
    if critique:
        all_critique_parts.append(critique)

    combined_critique = "\n\n".join(all_critique_parts)
    return final_score, combined_critique


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

        # 3. Initial draft prompt
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

        # 4. Generate initial draft
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

        current_draft = await ollama_client.generate_streaming(prompt, on_token=_on_token)
        if not current_draft.strip():
            raise ValueError("Ollama returned an empty response. Try a smaller file or check if the model is loaded.")

        # 5. Verification & refinement loop (up to 3 attempts, target >= 90%)
        best_draft = current_draft
        best_score = -1
        best_feedback = ""
        max_iterations = 3

        for attempt in range(1, max_iterations + 1):
            job_store.update_job(
                job_id,
                iteration=attempt,
                stage="evaluating",
                stage_message=f"Attempt {attempt}/{max_iterations}: Auditing draft vs source context (assumptions & completeness)...",
            )
            logger.info(f"Job {job_id}: Evaluating draft (attempt {attempt}/{max_iterations})")

            score, feedback = await _evaluate_and_score(
                source_context=extracted_text,
                draft_content=current_draft,
                pyq_topics=pyq_topics,
            )
            logger.info(f"Job {job_id}: Attempt {attempt} efficiency score={score}%")

            # Track best draft seen across iterations
            if score > best_score:
                best_score = score
                best_draft = current_draft
                best_feedback = feedback

            job_store.update_job(
                job_id,
                efficiency_score=score,
                evaluation_feedback=feedback,
            )

            # Success threshold reached!
            if score >= 90:
                logger.info(f"Job {job_id}: Passed quality threshold with {score}% on attempt {attempt}")
                break

            # If under 90% and more attempts remain, refine with Gemma
            if attempt < max_iterations:
                job_store.update_job(
                    job_id,
                    stage="refining",
                    stage_message=f"Score is {score}% (<90%). Attempt {attempt + 1}/{max_iterations}: Gemma is addressing critique & refining...",
                    partial_text="",
                )
                logger.info(f"Job {job_id}: Refining course content for attempt {attempt + 1}")

                refine_prompt = prompt_builder.build_refinement_prompt(
                    source_context=extracted_text,
                    previous_draft=current_draft,
                    critique=feedback,
                    format_template=format_template,
                    pyq_topics=pyq_topics,
                )

                refine_first_token = False
                async def _on_refine_token(chunk: str) -> None:
                    nonlocal refine_first_token
                    if not refine_first_token:
                        refine_first_token = True
                        job_store.update_job(
                            job_id,
                            stage="generating",
                            stage_message=f"Attempt {attempt + 1}/{max_iterations}: Gemma 4 is writing refined content...",
                        )
                    job_store.append_token(job_id, chunk)

                refined_draft = await ollama_client.generate_streaming(refine_prompt, on_token=_on_refine_token)
                if refined_draft.strip():
                    current_draft = refined_draft

        # Loop completed: use best draft found
        final_score = best_score if best_score >= 0 else 0
        if final_score >= 90:
            final_stage_msg = f"Verified with {final_score}% efficiency score!"
        else:
            final_stage_msg = f"Completed at {final_score}% after {max_iterations} attempts."

        logger.info(f"Job {job_id}: complete — returning best draft (score={final_score}%)")
        job_store.update_job(
            job_id,
            status="done",
            stage="done",
            stage_message=final_stage_msg,
            efficiency_score=final_score,
            evaluation_feedback=best_feedback,
            result_text=best_draft,
            partial_text=best_draft,
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
# Background task: run web search and generation with verification loop
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
        import asyncio
        loop = asyncio.get_running_loop()

        job_store.update_job(
            job_id,
            stage="generating",
            stage_message="Analyzing sources and generating course content...",
        )

        # 1. Generate initial draft and capture the exact search context block
        gen_result = await loop.run_in_executor(
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
                return_source=True,
            )
        )

        if isinstance(gen_result, tuple):
            initial_draft, source_context = gen_result
        else:
            initial_draft, source_context = gen_result, ""

        if not source_context:
            source_context = f"Topic: {topic}"

        # 2. Verification and refinement loop (up to 3 attempts, target >= 90%)
        current_draft = initial_draft
        best_draft = current_draft
        best_score = -1
        best_feedback = ""
        max_iterations = 3

        for attempt in range(1, max_iterations + 1):
            job_store.update_job(
                job_id,
                iteration=attempt,
                stage="evaluating",
                stage_message=f"Attempt {attempt}/{max_iterations}: Auditing content against web sources...",
            )
            logger.info(f"Job {job_id} (search): Evaluating draft (attempt {attempt}/{max_iterations})")

            score, feedback = await _evaluate_and_score(
                source_context=source_context,
                draft_content=current_draft,
                pyq_topics=None,
            )
            logger.info(f"Job {job_id} (search): Attempt {attempt} efficiency score={score}%")

            if score > best_score:
                best_score = score
                best_draft = current_draft
                best_feedback = feedback

            job_store.update_job(
                job_id,
                efficiency_score=score,
                evaluation_feedback=feedback,
            )

            if score >= 90:
                logger.info(f"Job {job_id} (search): Quality threshold passed with {score}%")
                break

            if attempt < max_iterations:
                job_store.update_job(
                    job_id,
                    stage="refining",
                    stage_message=f"Score is {score}% (<90%). Attempt {attempt + 1}/{max_iterations}: Refining content with web sources...",
                    partial_text="",
                )
                logger.info(f"Job {job_id} (search): Refining content for attempt {attempt + 1}")

                refine_prompt = prompt_builder.build_refinement_prompt(
                    source_context=source_context,
                    previous_draft=current_draft,
                    critique=feedback,
                    format_template=None,
                    pyq_topics=None,
                )

                refined_draft = await ollama_client.generate_streaming(
                    refine_prompt,
                    on_token=lambda chunk: job_store.append_token(job_id, chunk),
                )
                if refined_draft.strip():
                    current_draft = refined_draft

        final_score = best_score if best_score >= 0 else 0
        if final_score >= 90:
            final_stage_msg = f"Verified with {final_score}% efficiency score!"
        else:
            final_stage_msg = f"Completed at {final_score}% after {max_iterations} attempts."

        logger.info(f"Job {job_id} (search): done — returning best draft (score={final_score}%)")
        job_store.update_job(
            job_id,
            status="done",
            stage="done",
            stage_message=final_stage_msg,
            efficiency_score=final_score,
            evaluation_feedback=best_feedback,
            result_text=best_draft,
            partial_text=best_draft,
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