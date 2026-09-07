def generate_course_section(
    topic: str,
    num_sources: int = 3,
    model: str = OLLAMA_MODEL,
    on_status: callable = None,
    return_source: bool = False,
) -> str | tuple[str, str]:
    """
    Searches the web for the topic (via SearXNG), pulls in real sources, and
    asks the model to write a course section grounded in that material.

    If SearXNG is unavailable the function falls back to LLM-only generation
    using the model's own knowledge. The caller is notified via on_status().

    Args:
        topic:         Course topic to generate content for.
        num_sources:   Max web results to fetch.
        model:         Ollama model tag.
        on_status:     Optional callable(message: str) for progress/warning updates.
        return_source: If True, returns (content, source_context).
    """

    def _notify(msg: str):
        if on_status:
            on_status(msg)

    # 1. Web search — graceful fallback when SearXNG is down
    raw_results, search_available, search_warning = web_search(topic, max_results=num_sources)

    if not search_available:
        _notify(
            f"⚠️ Web search unavailable — {search_warning}. "
            "Continuing with model knowledge only."
        )

    # 2. Fetch full page text for each valid result
    sources_text = []
    if search_available and raw_results:
        _notify(f"Fetching {len(raw_results)} source(s)…")
        for r in raw_results:
            page_text = fetch_page(r["url"])
            sources_text.append(
                f"SOURCE: {r['title']} ({r['url']})\n{page_text or r['snippet']}"
            )

    context_block = ""
    # 3. Build prompt — adapts based on whether we have web context
    if sources_text:
        context_block = "\n\n---\n\n".join(sources_text)
        system_prompt = (
            "You are an expert course writer. Use the provided web sources to write "
            "accurate, up-to-date course content. Cite source URLs inline where relevant. "
            "If the sources don't cover something, rely on your own knowledge but say so."
        )
        user_prompt = (
            f'Write a course section on: "{topic}"\n\n'
            f"Here is current reference material gathered from the web:\n\n"
            f"{context_block}\n\n"
            "Write clear, well-structured course content (with headings and examples "
            "where useful) based on this material."
        )
    else:
        # Offline / fallback path
        system_prompt = (
            "You are an expert course writer. Web search is currently unavailable, "
            "so rely entirely on your own knowledge. Write thorough, accurate content "
            "and note where information may have evolved after your training cut-off."
        )
        user_prompt = (
            f'Write a comprehensive course section on: "{topic}"\n\n'
            "Include clear headings, key concepts, practical examples, and a summary. "
            "Note that no live web sources were available for this generation."
        )

    _notify("Generating course content with the local model…")

    # 1-hour timeout — generous for CPU-based generation, but still bounded.
    # num_predict=32768 and num_ctx=32768 to match ollama_client.py settings.
    client = ollama.Client(timeout=3600.0)
    response = client.chat(
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        options={
            "num_predict": 32768,
            "num_ctx": 32768,
        },
    )
    content = response["message"]["content"]
    if return_source:
        return content, context_block
    return content