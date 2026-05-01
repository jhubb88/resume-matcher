# AI Resume Matcher

Resume-to-job-description analysis tool powered by Claude — returns a match score, skill gaps, resume highlights, and coaching suggestions.

**Live demo:** https://d3t6z67os7y9is.cloudfront.net

## Overview

The AI Resume Matcher compares a resume against a job description using Claude (claude-sonnet-4-6) and returns a structured analysis report. The frontend submits the job to an AWS Lambda function via API Gateway, then polls for the result while Lambda processes the analysis asynchronously and stores it in S3. Accepts resumes as plain text or PDF.

## Features

- **Resume upload** — drag-and-drop or browse for `.txt` or `.pdf`; PDF text extraction handled server-side
- **Match score** — integer 0–100 weighted by skills match (40%), experience relevance (30%), keyword/ATS alignment (20%), presentation (10%)
- **Hiring likelihood** — five-tier label: Long Shot / Getting There / Solid Match / Strong Candidate / Dream Candidate
- **Personal summary** — 2–3 sentences addressed directly to the candidate
- **Strengths** — 3–5 items, each with specific evidence from the resume
- **Missing skills** — 3–6 gaps with importance level (critical / moderate / nice-to-have) and actionable tips
- **Resume highlights** — 6–10 exact phrases from the resume labeled as strength or improve, with coaching notes
- **Top suggestions** — 3–5 specific, actionable edits
- **Async processing** — frontend polls `/result/{jobId}` while Lambda works; UI shows a loading state

## Tech stack

| Layer | Technology |
|---|---|
| Frontend | Vanilla HTML5, CSS3, JavaScript |
| Backend | AWS Lambda (Python 3.11) + API Gateway |
| AI | Anthropic API — claude-sonnet-4-6 |
| PDF parsing | pypdf |
| Result storage | AWS S3 (`jimmy-resume-matcher-results`) |
| Frontend hosting | AWS S3 + CloudFront |

## Architecture

The frontend posts `{name, resume_base64, resume_type, job_description}` to `POST /analyze` on API Gateway. Lambda stores a `pending` status in S3 and self-invokes asynchronously to run the analysis. The async worker calls the Anthropic API with a structured prompt, parses the JSON response, and writes the result to `{jobId}/result.json` in S3. The frontend polls `GET /result/{jobId}` every few seconds until the result is available, then renders the report. The Anthropic API key is stored as an encrypted Lambda environment variable.

## Local development

The frontend can be served locally:

```bash
python3 -m http.server 8080
```

The backend requires a deployed Lambda and API Gateway — it cannot be run locally without additional setup. The `API_BASE` constant in `index.html` points to the deployed API Gateway URL.

## Deployment

`deploy.sh` automates full infrastructure creation:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script creates the IAM role, packages and deploys the Lambda, configures API Gateway, and creates the required S3 buckets. It prompts for the Anthropic API key and sets it as an encrypted Lambda environment variable.

To update only the frontend after changes to `index.html`:

Frontend deploys automatically on push to main via GitHub Actions (.github/workflows/deploy.yml) — S3 sync + CloudFront invalidation handled by the workflow.

**S3 bucket (frontend):** `jimmy-resume-matcher` (us-east-1)  
**S3 bucket (results):** `jimmy-resume-matcher-results` (us-east-1)  
**API Gateway:** `https://1kj7anef1b.execute-api.us-east-1.amazonaws.com/prod`

## Environment variables

The Lambda function requires one environment variable set at deploy time:

| Variable | Purpose |
|---|---|
| `ANTHROPIC_API_KEY` | Anthropic API key — set as encrypted Lambda env var by `deploy.sh` |

## Project structure

```
resume-matcher/
├── index.html              # Frontend — upload UI, polling logic, results display
├── lambda_function.py      # Lambda handler — API Gateway routing, async job dispatch, Claude call
└── deploy.sh               # Full infra deploy script (IAM, Lambda, API Gateway, S3)
```

## License

MIT — see [LICENSE](LICENSE)

## Author

Jimmy Hubbard — [github.com/jhubb88](https://github.com/jhubb88)

---

*Part of [jhubb88's portfolio](https://jimmyhubbard2.cc)*
