# MatrixF AI Server

Local FastAPI server that runs on your PC and handles AI course generation for
the **matrixf** Flutter app.  It extracts text from PDFs / DOCX / images,
builds a structured prompt, and sends it to your locally-running Gemma 4 model
via Ollama.

---

## Prerequisites

### 1 — Ollama (already done ✓)
You have `gemma4:latest` installed.  Confirm it's running:
```powershell
ollama serve          # starts the Ollama daemon (if not already running)
ollama list           # should show gemma4:latest
```

### 2 — Tesseract OCR (needed for scanned PDFs & image files)
Download and install the Windows binary from:
https://github.com/UB-Mannheim/tesseract/wiki

**During installation, tick "Add to PATH".**

Confirm:
```powershell
tesseract --version
```

If Tesseract is installed but NOT on PATH, set the full path in a `.env` file
or at the top of `ingestor.py`:
```python
import pytesseract
pytesseract.pytesseract.tesseract_cmd = r'C:\Program Files\Tesseract-OCR\tesseract.exe'
```

### 3 — Python 3.11+
```powershell
python --version    # should be 3.11+
```

---

## Setup

```powershell
cd C:\Users\ABHIJITH\matrixf\ai_server

# Create virtual environment (one-time)
python -m venv .venv
.venv\Scripts\Activate.ps1

# Install dependencies
pip install -r requirements.txt
```

---

## Configuration (Environment Variables)

| Variable | Default | Description |
|---|---|---|
| `AI_SERVER_API_KEY` | `changeme-set-in-env` | Shared secret — set same value in the Flutter app settings |
| `OLLAMA_MODEL` | `gemma4:latest` | Ollama model tag to use |
| `OLLAMA_HOST` | `http://localhost:11434` | Ollama API base URL |

Set them in PowerShell before starting:
```powershell
$env:AI_SERVER_API_KEY = "your-secret-key"
$env:OLLAMA_MODEL = "gemma4:latest"
```

Or create a `.env` file and source it (or use python-dotenv if you add it).

---

## Starting the Server

```powershell
# From the ai_server directory, with venv active:
uvicorn main:app --host 0.0.0.0 --port 8000 --reload
```

The server will be reachable from your phone at:
- **Same Wi-Fi**: `http://<your-laptop-IP>:8000`  (find IP with `ipconfig`)
- **Tailscale**: `http://<tailscale-IP>:8000`

### Firewall (one-time, run as admin)
```powershell
New-NetFirewallRule -DisplayName "MatrixF AI Server" -Direction Inbound -Protocol TCP -LocalPort 8000 -Action Allow
```

---

## Testing the Server

```powershell
# Health check (no API key needed)
curl http://localhost:8000/health

# Start a generation job with a PDF
curl -X POST http://localhost:8000/ingest `
  -H "X-API-Key: your-secret-key" `
  -F "files=@C:\path\to\your.pdf" `
  -F "mode=create" `
  -F "format_template=Generate comprehensive module content with clear headings."

# Poll status (replace JOB_ID with the id returned above)
curl http://localhost:8000/status/JOB_ID -H "X-API-Key: your-secret-key"
```

---

## API Reference

### `GET /health`
No auth required. Returns Ollama + Tesseract status.

### `POST /ingest`
**Headers**: `X-API-Key: <key>`
**Form fields**:

| Field | Type | Required | Description |
|---|---|---|---|
| `files[]` | File | No | PDF/DOCX/JPG/PNG — can send multiple |
| `raw_text` | string | No | Pasted plain text |
| `mode` | string | No | `"create"` (default) or `"enhance"` |
| `format_template` | string | No | Custom formatting instructions |
| `pyq_topics` | string | No | JSON array `["topic1","topic2"]` or comma-separated |
| `existing_content` | string | No | Current module content (required for enhance mode) |

**Returns**: `{"job_id": "..."}`

### `GET /status/{job_id}`
**Headers**: `X-API-Key: <key>`
**Returns**: `{"job_id":"...","status":"done","result_text":"...","error_message":null}`

Status values: `pending` → `processing` → `done` / `failed`
