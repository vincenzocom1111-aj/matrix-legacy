import time
import httpx
import fitz

# 1. Create a clean 1-page PDF with text (simulating real course content)
doc = fitz.open()
page = doc.new_page()
content = """
Chapter 1: Amplitude Modulation (AM) Fundamentals

Amplitude Modulation is a modulation technique used in electronic communication,
most commonly for transmitting messages with a radio wave. In amplitude modulation,
the amplitude (signal strength) of the carrier wave is varied in proportion to that
of the message signal, such as an audio signal.

Key Concepts:
1. Carrier Wave: High frequency signal c(t) = Ac * cos(2 * pi * fc * t)
2. Modulating Signal: Low frequency baseband signal m(t) = Am * cos(2 * pi * fm * t)
3. Modulation Index (mu): Ratio of Am to Ac. For distortion-free transmission, mu <= 1.
4. Total Bandwidth: BW = 2 * fm

Applications:
- AM broadcast radio (535 kHz to 1605 kHz)
- Aircraft VHF communications
- Shortwave radio broadcasts
"""
page.insert_text((50, 72), content, fontsize=11)
pdf_bytes = doc.tobytes()
doc.close()

# 2. Submit to /ingest
API_KEY = "matrix-abhi-2005"
BASE_URL = "http://127.0.0.1:8000"

print("--- Submitting /ingest request ---")
t0 = time.time()
with httpx.Client(timeout=30.0) as client:
    resp = client.post(
        f"{BASE_URL}/ingest",
        headers={"X-API-Key": API_KEY},
        data={"mode": "create", "format_template": "Keep it concise: 2 modules maximum."},
        files=[("files", ("am_modulation.pdf", pdf_bytes, "application/pdf"))],
    )
    resp.raise_for_status()
    job_id = resp.json()["job_id"]
    print(f"Job created: {job_id}")

# 3. Poll /status in a tight loop and record exact timestamps
t_first_token = None
t_done = None
last_stage = None
last_tokens = 0

with httpx.Client(timeout=10.0) as client:
    while True:
        r = client.get(f"{BASE_URL}/status/{job_id}", headers={"X-API-Key": API_KEY})
        if r.status_code != 200:
            print(f"Poll error: {r.status_code}")
            time.sleep(1)
            continue
        data = r.json()
        status = data.get("status")
        stage = data.get("stage")
        stage_msg = data.get("stage_message")
        tokens = data.get("tokens_generated", 0)
        elapsed = time.time() - t0

        if stage != last_stage or (tokens > 0 and last_tokens == 0):
            print(f"[{elapsed:6.2f}s] Stage: {stage} | Msg: {stage_msg} | Tokens: {tokens}")
            last_stage = stage

        if tokens > 0 and t_first_token is None:
            t_first_token = time.time()
            print(f"==> FIRST TOKEN ARRIVED at +{t_first_token - t0:.2f}s!")

        last_tokens = tokens

        if status == "done":
            t_done = time.time()
            print(f"==> GENERATION DONE at +{t_done - t0:.2f}s!")
            print(f"Total tokens generated: {tokens}")
            print(f"Result length: {len(data.get('result_text', ''))} characters")
            break
        elif status == "failed":
            print(f"==> FAILED: {data.get('error_message')}")
            break

        time.sleep(0.5)

print("\n================== TIMING REPORT ==================")
print(f"Job Start to First Token: {t_first_token - t0:.2f} seconds")
print(f"First Token to Done:      {t_done - t_first_token:.2f} seconds")
print(f"Total Wall-Clock Time:    {t_done - t0:.2f} seconds")
if t_done and t_first_token and (t_done - t_first_token) > 0:
    speed = tokens / (t_done - t_first_token)
    print(f"Generation Speed:         {speed:.2f} tokens/second")
print("===================================================\n")
