"""
Async client for Ollama's local API — streaming mode.

Uses /api/generate with stream=True so each token is received as soon as
Ollama emits it.  The caller passes an on_token callback that is invoked
for every token, allowing the job store to accumulate partial text in
real-time.
"""
import json
import httpx
from typing import Callable, Awaitable, Optional
from config import OLLAMA_HOST, OLLAMA_MODEL


async def generate_streaming(
    prompt: str,
    on_token: Callable[[str], Awaitable[None]],
    model: str = OLLAMA_MODEL,
) -> str:
    """
    Stream a generation from Ollama.

    Calls on_token(chunk) for every text fragment received.
    Returns the complete accumulated response string when done.

    Raises httpx.HTTPError on network or server errors.
    Timeout = 1 hour — generous for large course generation on CPU.
    num_predict = 32768 — large output cap; well beyond typical course length.
    num_ctx = 32768 — large context window so big prompts aren't truncated.
    """
    url = f"{OLLAMA_HOST}/api/generate"
    payload = {
        "model": model,
        "prompt": prompt,
        "stream": True,
        "options": {
            "temperature": 0.4,
            "num_predict": 32768,   # large output cap (was 8192)
            "num_ctx": 32768,       # large context window for big prompts
        },
    }

    full_response: list[str] = []

    # 1-hour timeout — generous for CPU-based generation, but still bounded
    async with httpx.AsyncClient(timeout=3600.0) as client:
        async with client.stream("POST", url, json=payload) as response:
            response.raise_for_status()
            async for line in response.aiter_lines():
                if not line.strip():
                    continue
                try:
                    data = json.loads(line)
                except json.JSONDecodeError:
                    continue

                chunk: str = data.get("response", "")
                if chunk:
                    full_response.append(chunk)
                    await on_token(chunk)

                # Ollama sends {"done": true} as the final message
                if data.get("done"):
                    break

    return "".join(full_response).strip()


async def check_health() -> bool:
    """Returns True if Ollama is reachable and responding."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{OLLAMA_HOST}/api/tags")
            return resp.status_code == 200
    except Exception:
        return False


async def list_models() -> list[str]:
    """Returns list of model names available in Ollama."""
    try:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(f"{OLLAMA_HOST}/api/tags")
            data = resp.json()
            return [m["name"] for m in data.get("models", [])]
    except Exception:
        return []
