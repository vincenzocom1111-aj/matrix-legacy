"""
In-memory job store.
Jobs are lost if the server restarts — acceptable for a local dev server.
If you later need persistence, swap _store for a SQLite dict.
"""
import threading
import uuid
from dataclasses import dataclass, field
from typing import Optional


@dataclass
class Job:
    job_id: str
    status: str = "pending"           # pending | processing | done | failed
    stage: str = "extracting"         # extracting | analyzing | generating | evaluating | refining | done | failed
    stage_message: str = ""           # Human-readable real-time progress message
    extracted_text: str = ""          # The extracted source text shown during analysis
    partial_text: str = ""            # accumulated tokens so far (live preview)
    result_text: Optional[str] = None # full result once done
    error_message: Optional[str] = None
    tokens_generated: int = 0         # token count, shown in progress UI
    elapsed_seconds: int = 0          # live elapsed duration
    efficiency_score: Optional[int] = None # percentage (0-100)
    evaluation_feedback: Optional[str] = None # feedback notes on assumptions, missing content, fixes
    iteration: int = 1                # current attempt number (1, 2, 3...)


_store: dict[str, Job] = {}
_lock = threading.Lock()


def create_job() -> Job:
    job_id = str(uuid.uuid4())
    job = Job(job_id=job_id)
    with _lock:
        _store[job_id] = job
    return job


def get_job(job_id: str) -> Optional[Job]:
    with _lock:
        return _store.get(job_id)


def append_token(job_id: str, chunk: str) -> None:
    """Append a streamed token to the job's partial_text. Thread-safe."""
    with _lock:
        job = _store.get(job_id)
        if job:
            job.partial_text += chunk
            job.tokens_generated += 1


def update_job(job_id: str, **kwargs) -> None:
    with _lock:
        job = _store.get(job_id)
        if job:
            for k, v in kwargs.items():
                setattr(job, k, v)
