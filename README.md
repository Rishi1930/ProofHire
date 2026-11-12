# ProofHire

ProofHire is an existing recruitment SaaS MVP built with React, TypeScript,
Vite, and Supabase. The browser client uses Supabase Auth and the public
Supabase key; workspace access remains enforced by database Row Level Security.

## Current capabilities

- Authentication, workspace onboarding, and workspace-scoped recruiter pages.
- Job creation and management, including required/preferred skills and minimum
  experience.
- Candidate and application management, application status changes, and public
  job application pages.
- Private candidate resume storage and recruiter-only resume access. Recruiters
  can optionally attach a PDF, DOC, or DOCX resume while creating an application
  or upload one later from Resume Screening. Each upload is linked to that
  application and job; candidate-level files are not silently reused.
- Manual recruiter decisions and internal interview scheduling, outcomes, and
  feedback.
- Workspace-scoped CSV, PDF, and XLSX exports. Exports do not contain private
  resume paths or signed URLs.

Resume screening uses a deterministic Go engine, not an AI API. It supports
PDF/DOC/DOCX extraction, configurable mandatory/preferred requirements,
weighted category scoring, literal-match evidence, persisted versioned
reports, and a per-job screening threshold. The worker uses the existing
lease-based Supabase screening queue and existing
`job_screening_criteria`/`application_screening_assessments` tables. The
additive deterministic-screening migration adds workspace-scoped supplemental
requirements and job scoring settings, and includes the settings in queue
fingerprints so requirement changes enqueue a fresh assessment. The owner
provided a read-only schema inventory that confirmed the existing job key,
screening tables, authorization functions, and absence of the new settings
table/columns. The deterministic screening configuration migration has not yet been applied to
the live project; see the live schema status below.
Screening scores are review signals and do not automatically reject candidates
or advance application stages.

The technical interview engine replaces the former aptitude assessment, which
has been removed from the product: the candidate assessment UI, the recruiter
authoring workspace, the Go aptitude endpoints and the aptitude email templates
are gone. An interview is now two server-timed phases in one session:

1. **Technical questions** — recruiter-authored per job, snapshotted into the
   session, autosaved answer by answer.
2. **Coding session** — one or more published coding challenges with sample
   tests shown and hidden tests scored by the ProofHire runner.

Candidates reach a session only through an opaque token that is hashed at rest
and expires; they never receive table grants. Interview questions, answers,
drafts, submissions and proctoring events are workspace-scoped under RLS. The
full-screen requirement, tab/window signals, paste/copy signals and the
server-side deadline are deterrents recorded in an audit trail, not proof of
integrity. Question scores are awarded by recruiters; coding scores are
deterministic test-case results. Resume screening remains deterministic and
advisory, and recruiter decisions remain human decisions.

## Requirements

- Node.js 22 or newer.
- npm.
- A Supabase project configured for ProofHire.

DOCX extraction uses Go's standard library. PDF extraction requires Poppler's
`pdftotext`; legacy DOC extraction requires `antiword`. Optional scanned-PDF OCR
requires Poppler's `pdfinfo` and `pdftoppm` plus Tesseract, and must be
explicitly enabled. The extractor validates file size, extension/MIME
agreement, signatures, archive paths and limits, and bounds converter time and
output. Uploaded files are processed by the separately started worker; parsing
has not been live-tested with actual local document utilities in this
environment.

## Local development

1. Install dependencies:

   ```powershell
   npm ci
   ```

2. Copy `.env.example` to `.env.local` and set the public Supabase project URL
   and anon/publishable key.
3. Start the Vite development server:

   ```powershell
   npm run dev
   ```

4. Validate the production bundle:

   ```powershell
   npm run build
   ```

`npm run build` also runs the TypeScript project build. The Go backend has
unit tests, but no automated frontend test suite is currently configured. A
successful build/test run does not verify live Supabase policies or
account-specific runtime behavior.

### Go backend and screening worker

Install Go 1.23 or newer. `.env.backend.example` is a reference only; Go
processes do not load dotenv files automatically. Configure `SUPABASE_SECRET_KEY`
with the new `sb_secret_` key format; the optional
`SUPABASE_SERVICE_ROLE_KEY` accepts a legacy service-role JWT and is used only
when `SUPABASE_SECRET_KEY` is unset. The new key takes precedence when both are
configured. Keep Supabase privileged credentials in server/worker secrets only;
never put them in `.env.local`, frontend code, or a `VITE_` variable. The worker
sends a new secret key only in the `apikey` header;
it uses the legacy JWT in both `apikey` and `Authorization: Bearer` headers.
Resume screening has no external AI or model credentials.

```powershell
$env:SUPABASE_URL = "https://your-project.supabase.co"
$env:SUPABASE_ANON_KEY = "your-supabase-anon-or-publishable-key"
$env:SUPABASE_SECRET_KEY = "sb_secret_your-project-secret-key"
# Optional legacy fallback:
# $env:SUPABASE_SERVICE_ROLE_KEY = "your-legacy-service-role-jwt"
go test ./...
```

After applying all migrations in timestamp order to a disposable local/test
Supabase database, run the API server and the worker in separate PowerShell
windows with the appropriate environment variables set in each:

```powershell
go run ./backend/cmd/server
```

```powershell
go run ./backend/cmd/worker
```

Worker settings include `SCREENING_WORKER_CONCURRENCY` (1–16),
`SCREENING_POLL_INTERVAL` (250ms–5m), and `RESUME_OCR_ENABLED` (default
`false`). PDF and DOC processing require the optional utilities above. The
worker uses the selected privileged credential only server-side for queue
claiming, private resume retrieval, and persistence; its SQL functions require
the service role and apply lease/idempotency checks. The backend also uses its
server-only privileged credential only for the email delivery queue and
webhook bookkeeping; the credential is never sent to the browser.

The backend verifies access tokens against Supabase Auth. Its existing endpoints are:

- `GET /api/health` — backend health.
- `GET /api/v1/me` — authenticated user ID only.
- `GET /api/v1/workspace-access?workspace_id=<uuid>` — the authenticated
  member's workspace role.
- `POST /api/v1/email-delivery/{jobID}/action` — recruiter-authorized delivery
  queue action (send, retry, resend).
- `POST /api/webhooks/resend` — signature-verified provider webhook for delivery
  events.

The former aptitude endpoints were removed together with the aptitude module.

Workspace access is queried with the caller's token, so Supabase RLS remains
active. The recruiter screening page reads persisted job-specific assessments
and can request processing/retry through permission-checked database functions.
The Vite development server proxies `/api` requests to `http://127.0.0.1:8080`;
run the Go server alongside `npm run dev`. Configure the server-only
`SUPABASE_SECRET_KEY` (or legacy `SUPABASE_SERVICE_ROLE_KEY`) for the email
delivery endpoints, the screening worker and the email worker.

### Email delivery (owner action)

The backend sends mail through your own SMTP server. No third-party email API is
required. Configure these only in the worker's secret environment, never in a
`VITE_` variable and never in Git:

| Variable | Purpose |
| --- | --- |
| `EMAIL_PROVIDER` | `smtp` (or `resend` for the optional HTTP client) |
| `SMTP_HOST` | SMTP server hostname |
| `SMTP_PORT` | 587 for STARTTLS, 465 for implicit TLS, 25 for a trusted relay |
| `SMTP_USERNAME` / `SMTP_PASSWORD` | Set both, or neither for an unauthenticated relay |
| `SMTP_SECURITY` | `starttls` (default), `tls`, or `none` (trusted relay only) |
| `EMAIL_FROM_ADDRESS` / `EMAIL_FROM_NAME` | Verified sender identity |
| `APP_BASE_URL` | Public site origin used in emailed links |

After configuring, restart the worker and read its log: `email delivery is
disabled` with a reason means the configuration was rejected and nothing will
send; no such line means the transport is live. Queued messages stay
`blocked_configuration` until a transport is available. SMTP has no provider
webhook, so delivery state is recorded from a successful SMTP exchange rather
than a vendor receipt.
email.

## Supabase configuration

Required frontend environment variables:

| Variable | Purpose |
| --- | --- |
| `VITE_SUPABASE_URL` | Supabase project URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key (preferred) |
| `VITE_SUPABASE_ANON_KEY` | Legacy anon key; used if the publishable-key variable is unset |

Only the anon/publishable key belongs in browser configuration. **Never put a
Supabase secret/service-role key or other server secret in a
`VITE_` variable.** The API server uses the anon/publishable key to verify
sessions and a server-only privileged credential for email delivery queue
operations. The isolated screening and email workers use that same privileged
credential and must be deployed as protected server processes, not in the
browser or a static Vite bundle.

Database migrations are in `supabase/migrations/`; read
[`supabase/database-architecture.md`](supabase/database-architecture.md) for the
repository audit, schema relationships, RLS rules, and safe test setup. The
Live schema status (verified 12 November 2026): the hosted project has the
core tables, the screening pipeline, the aptitude/coding/interview tables and
the public application RPC, but it is missing `account_deletion_requests`,
`application_notes`, and the deterministic screening configuration
(`jobs.minimum_screening_percentage`, `jobs.screening_weights`,
`job_screening_requirements` and `replace_job_screening_requirements`). Until
the three aptitude-free migrations in
[`supabase/operations/P0_RUNBOOK.md`](supabase/operations/P0_RUNBOOK.md) are
applied, the jobs page and job creation fail against the live project. The
technical interview migration `202611120001_technical_interview_engine.sql` must
be applied after those three; without it the interview engine pages have no
storage.

Verify the target is a disposable local/test database before applying them; never run a local reset or migration command against production. The resume
bucket must remain private. Do not grant anonymous users direct
candidate/application/assessment table permissions.

The screening engine performs exact phrase and structured experience matching
locally. Scores include unmatched requirements in the denominator; partial
matches receive half weight. Absence of a resume phrase is recorded as missing
evidence, not proof the candidate lacks a qualification. Explicitly stated
absence can be marked not met only where the resume says so directly. The live
project was reachable on 12 November 2026, but no signed-in RLS or full database
integration test has been run from this repository, and the screening
configuration migration is still missing there. Recruiter job settings and
requirements must be saved after that migration is applied; changing them
queues screening again. Existing application records without a stored
resume cannot be reconstructed from their candidate record; recruiters must
attach the original document to that application before screening. Screening
results are advisory: authorized recruiters make and audit application-stage
decisions separately.

## Technical interview engine

The interview engine adds four moving parts:

1. `supabase/migrations/202611120001_technical_interview_engine.sql` — question
   bank, sessions, answers, drafts, submissions, proctoring events, recruiter
   and worker RPCs.
2. `src/interviews/CandidateInterview.tsx` — the candidate experience at
   `/interview/:token` (full-screen gate, server timer, autosave, code editor).
3. `src/interviews/InterviewWorkspace.tsx` — the recruiter workspace at
   `/interviews/technical` (question bank, session creation, review and scoring).
4. `backend/runner` + `backend/interview` — the sandboxed execution engine and
   the evaluation worker.

### Runner host

Candidate code executes in disposable Docker containers. The worker therefore
needs a host with the Docker daemon and cgroup limits — not Vercel and not a
serverless runtime. A single small VPS is enough to start; add replicas of
`go run ./backend/cmd/worker` to scale, because submissions are leased from a
database queue and never delivered twice.

```bash
# one-time: prepare the images you support
docker pull python:3.12-alpine
docker pull node:22-alpine
docker pull golang:1.23-alpine

# start the workers (screening + email + interview evaluation)
CODE_RUNNER_ENABLED=true \
RUNNER_PREWARM_LANGUAGES=python,javascript,go \
go run ./backend/cmd/worker
```

The sandbox runs with no network, a read-only root filesystem, a 64 MiB writable
tmpfs, capped memory/CPU/processes, a non-root user and a hard wall-clock
deadline. Run the integration test on that host (it exercises real containers,
network isolation and the timeout):

```bash
go test ./backend/runner -run TestPythonExecution -v
```

Supported languages are `python`, `javascript`, `go`, `cpp` and `java`; each is
an image plus two commands in `backend/runner/runner.go`.

## GitHub checks

GitHub Actions runs `npm ci`, the production build, and an npm vulnerability
audit on pushes and pull requests, then runs the Go backend test suite. The
frontend build does not require Supabase credentials; runtime Supabase
operations do.

## Vercel deployment

The Vercel configuration rewrites client-side React Router paths to the Vite
entry point. To deploy:

1. Import this repository into the intended Vercel team/account.
2. Use the Vite framework preset, `npm run build` as the build command, and
   `dist` as the output directory.
3. Configure `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` in the Vercel
   project's environment settings for the required environments. Configure
   `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SECRET_KEY` for the Go
   function as well; these are server-side environment variables and must not
   use the `VITE_` prefix.
4. Configure the deployed site URL in the Supabase Auth redirect/site URL
   settings and verify private storage and RLS policies.
5. Deploy only after reviewing the build, configured environment, and target
   Supabase migration state.

No Vercel deployment or GitHub push is performed by this repository's build
configuration. Verify the connected repository and Vercel project before
enabling automatic production deployments.

## Export and sharing boundaries

Exports use real workspace-scoped database reads and do not include raw resume
paths or signed URLs. Recruiter-decision and interview worksheets require the
corresponding migrations to be applied. Candidate profile links are internal:
recipients must authenticate and have access to the relevant workspace.
Revocable external share links and external candidate reports are not
implemented.
