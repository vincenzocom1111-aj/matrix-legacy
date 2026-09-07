import os
import requests
from bs4 import BeautifulSoup
import ollama
from config import SEARXNG_BASE_URL

OLLAMA_MODEL = "gemma3"          # match whatever tag you pulled, e.g. "gemma3:12b"


# ---------- SEARCH + FETCH HELPERS ----------

def _check_searxng_available() -> tuple[bool, str]:
    """
    Quick connectivity probe to SearXNG.
    Returns (is_available, error_message).
    """
    try:
        resp = requests.get(
            f"{SEARXNG_BASE_URL.rstrip('/')}/",
            timeout=5,
            headers={"User-Agent": "MatrixF-AI-Server/1.0"},
        )
        # SearXNG returns 200 on its home page
        return (resp.status_code < 500, "")
    except requests.exceptions.ConnectionError:
        return (False, f"SearXNG is not reachable at {SEARXNG_BASE_URL} — is it running?")
    except requests.exceptions.Timeout:
        return (False, f"SearXNG timed out at {SEARXNG_BASE_URL}.")
    except Exception as e:
        return (False, str(e))


def web_search(query: str, max_results: int = 5) -> tuple[list[dict], bool, str]:
    """
    Search via a local SearXNG instance (no API key required).
    SearXNG must have the 'json' format enabled in its settings.yml.

    Returns:
        (results, search_available, warning_message)
        - results: list of {title, url, snippet} dicts (empty when unavailable)
        - search_available: False when SearXNG could not be reached
        - warning_message: human-readable reason when search_available is False
    """
    available, err = _check_searxng_available()
    if not available:
        return [], False, err

    try:
        resp = requests.get(
            f"{SEARXNG_BASE_URL.rstrip('/')}/search",
            params={
                "q": query,
                "format": "json",
                "engines": "google,bing,duckduckgo",
                "language": "en",
            },
            headers={"User-Agent": "MatrixF-AI-Server/1.0"},
            timeout=15,
        )
        resp.raise_for_status()
        data = resp.json()
        items = data.get("results", [])[:max_results]
        results = [
            {
                "title": r.get("title", ""),
                "url": r.get("url", ""),
                "snippet": r.get("content", "")[:500],
            }
            for r in items
        ]
        return results, True, ""
    except Exception as e:
        return [], False, f"SearXNG search failed: {e}"


def fetch_page(url: str, char_limit: int = 3000) -> str:
    try:
        resp = requests.get(url, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
        resp.raise_for_status()
        soup = BeautifulSoup(resp.text, "html.parser")
        for tag in soup(["script", "style", "nav", "footer", "header"]):
            tag.decompose()
        text = " ".join(soup.get_text(separator=" ").split())
        return text[:char_limit]
    except Exception:
        return ""


# ---------- AUTOMATIC-SEARCH COURSE GENERATION ----------

def generate_course_section(
    topic: str,
    num_sources: int = 3,
    model: str = OLLAMA_MODEL,
    on_status: callable = None,
) -> str:
    """
    Searches the web for the topic (via SearXNG), pulls in real sources, and
    asks the model to write a course section grounded in that material.

    If SearXNG is unavailable the function falls back to LLM-only generation
    using the model's own knowledge. The caller is notified via on_status().

    Args:
        topic:       Course topic to generate content for.
        num_sources: Max web results to fetch.
        model:       Ollama model tag.
        on_status:   Optional callable(message: str) for progress/warning updates.
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
    return response["message"]["content"]


# ---------- QUICK LOCAL TEST ----------
if __name__ == "__main__":
    def _print_status(msg):
        print(f"[STATUS] {msg}")

    print(generate_course_section(
        "Latest best practices in prompt engineering 2026",
        on_status=_print_status,
    ))
