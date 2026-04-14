import json
import base64
import os
import io
import uuid
import boto3
import anthropic
from pypdf import PdfReader


RESULTS_BUCKET = "jimmy-resume-matcher-results"
CORS_HEADERS = {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
}

s3 = boto3.client("s3", region_name="us-east-1")
lambda_client = boto3.client("lambda", region_name="us-east-1")


def lambda_handler(event, context):
    # ── Async worker invocation (no httpMethod) ──────────────────────────────
    if "job_id" in event and "httpMethod" not in event:
        return process_job(event)

    http_method = event.get("httpMethod", "")
    path = event.get("path", "/")

    # ── CORS preflight ────────────────────────────────────────────────────────
    if http_method == "OPTIONS":
        return {"statusCode": 200, "headers": CORS_HEADERS, "body": ""}

    # ── GET /result/{jobId} — poll for result ─────────────────────────────────
    if http_method == "GET" and "/result/" in path:
        job_id = path.split("/result/")[-1].strip("/")
        return get_result(job_id)

    # ── POST /analyze — start new analysis ───────────────────────────────────
    if http_method == "POST":
        return start_analysis(event, context)

    return error_response(405, "Method not allowed")


# ── Start analysis ────────────────────────────────────────────────────────────

def start_analysis(event, context):
    try:
        body = json.loads(event.get("body", "{}"))
    except json.JSONDecodeError:
        return error_response(400, "Invalid JSON body")

    name            = body.get("name", "").strip()
    resume_base64   = body.get("resume_base64", "")
    resume_type     = body.get("resume_type", "txt").lower()
    job_description = body.get("job_description", "").strip()

    if not name:
        return error_response(400, "Name is required")
    if not resume_base64:
        return error_response(400, "Resume file is required")
    if len(job_description) < 20:
        return error_response(400, "Job description is too short")

    job_id = uuid.uuid4().hex[:12]

    # Mark as in-progress
    s3.put_object(
        Bucket=RESULTS_BUCKET,
        Key=f"{job_id}/status.json",
        Body=json.dumps({"status": "processing"}),
        ContentType="application/json",
    )

    # Invoke self asynchronously to do the actual Claude call
    lambda_client.invoke(
        FunctionName=context.function_name,
        InvocationType="Event",
        Payload=json.dumps({
            "job_id": job_id,
            "name": name,
            "resume_base64": resume_base64,
            "resume_type": resume_type,
            "job_description": job_description,
        }),
    )

    return {
        "statusCode": 200,
        "headers": CORS_HEADERS,
        "body": json.dumps({"job_id": job_id}),
    }


# ── Async worker ──────────────────────────────────────────────────────────────

def process_job(event):
    job_id          = event["job_id"]
    name            = event["name"]
    resume_base64   = event["resume_base64"]
    resume_type     = event.get("resume_type", "txt")
    job_description = event["job_description"]

    try:
        file_bytes = base64.b64decode(resume_base64)

        if resume_type == "pdf":
            resume_text = extract_pdf_text(file_bytes)
        else:
            resume_text = file_bytes.decode("utf-8", errors="replace")

        if not resume_text.strip():
            raise ValueError("Could not extract text from resume")

        result = analyze_with_claude(name, resume_text, job_description)
        result["resume_text"] = resume_text
        result["status"] = "done"

        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=f"{job_id}/result.json",
            Body=json.dumps(result),
            ContentType="application/json",
        )

    except Exception as e:
        s3.put_object(
            Bucket=RESULTS_BUCKET,
            Key=f"{job_id}/result.json",
            Body=json.dumps({"status": "error", "error": str(e)}),
            ContentType="application/json",
        )


# ── Poll for result ───────────────────────────────────────────────────────────

def get_result(job_id):
    try:
        obj = s3.get_object(Bucket=RESULTS_BUCKET, Key=f"{job_id}/result.json")
        result = json.loads(obj["Body"].read())
        return {
            "statusCode": 200,
            "headers": CORS_HEADERS,
            "body": json.dumps(result),
        }
    except s3.exceptions.NoSuchKey:
        # Still processing
        return {
            "statusCode": 202,
            "headers": CORS_HEADERS,
            "body": json.dumps({"status": "processing"}),
        }
    except Exception as e:
        return error_response(500, str(e))


# ── Claude analysis ───────────────────────────────────────────────────────────

def extract_pdf_text(file_bytes: bytes) -> str:
    reader = PdfReader(io.BytesIO(file_bytes))
    pages = []
    for page in reader.pages:
        text = page.extract_text()
        if text:
            pages.append(text)
    return "\n\n".join(pages)


def analyze_with_claude(name: str, resume_text: str, job_description: str) -> dict:
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])

    prompt = f"""You are an expert resume analyst and career coach. Analyze the resume below against the job description and return ONLY a valid JSON object — no markdown, no explanation, no code fences.

Candidate name: {name}

RESUME:
---
{resume_text}
---

JOB DESCRIPTION:
---
{job_description}
---

Return exactly this JSON structure:
{{
  "match_score": <integer 0-100. Weight: skills match 40%, experience relevance 30%, keyword/ATS alignment 20%, overall presentation 10%>,
  "hiring_likelihood": <one of: "Long Shot" | "Getting There" | "Solid Match" | "Strong Candidate" | "Dream Candidate">,
  "personal_summary": "<2-3 honest, warm, specific sentences addressed directly to {name} about their overall fit. Be encouraging but real.>",
  "strengths": [
    {{"skill": "<specific skill or quality>", "evidence": "<exact evidence from their resume that demonstrates this>"}}
  ],
  "missing_skills": [
    {{"skill": "<skill or experience gap>", "importance": "<critical | moderate | nice-to-have>", "tip": "<specific, actionable advice for {name} on how to address this>"}}
  ],
  "resume_highlights": [
    {{"phrase": "<exact phrase copied from the resume>", "type": "<strength | improve>", "note": "<brief coaching note>"}}
  ],
  "top_suggestions": [
    "<specific, actionable suggestion — not generic advice>"
  ]
}}

Rules:
- strengths: 3-5 items
- missing_skills: 3-6 items
- resume_highlights: 6-10 items. "strength" = phrases that align well with the JD. "improve" = phrases that could be reworded for more impact.
- top_suggestions: 3-5 items, each concrete and specific to this resume + job
- match_score must be an integer
- ALL phrases in resume_highlights must appear word-for-word in the resume text
- Address {name} by name in personal_summary"""

    message = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=4096,
        messages=[{"role": "user", "content": prompt}],
    )

    raw = message.content[0].text.strip()
    if raw.startswith("```"):
        raw = raw.split("\n", 1)[1] if "\n" in raw else raw
        raw = raw.rsplit("```", 1)[0]

    return json.loads(raw)


def error_response(status: int, message: str) -> dict:
    return {
        "statusCode": status,
        "headers": CORS_HEADERS,
        "body": json.dumps({"error": message}),
    }
