import os

# Ollama settings
OLLAMA_HOST: str = os.getenv("OLLAMA_HOST", "http://localhost:11434")
OLLAMA_MODEL: str = os.getenv("OLLAMA_MODEL", "gemma4:e4b")

# A simple shared-secret used as X-API-Key header on every request.
# Set this in your .env or shell before starting the server.
# The Flutter app must send the same value in the X-API-Key header.
API_KEY: str = os.getenv("AI_SERVER_API_KEY", "changeme-set-in-env")

# SearXNG — self-hosted search engine (no API key needed).
# Point this to your local Docker instance or any SearXNG deployment.
SEARXNG_BASE_URL: str = os.getenv("SEARXNG_BASE_URL", "http://localhost:8080")
