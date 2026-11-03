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
table/columns. The migration has not been applied or live-tested; configured
Supabase REST requests still return HTTP 401.
Screening scores are review signals and do not automatically reject candidates
or advance application stages.

The aptitude workflow includes test authoring and publishing, manually
delivered invitations, candidate sessions, autosaved answers, server-side
scoring, and recruiter-facing results. Passing a configured threshold is only
a recommendation; application stages are never changed automatically.
Recruiters can schedule interviews and record outcomes and feedback.

The new database migrations add application-stage history, richer interview
records, coding-assessment configuration and private submission/evaluation
queues, email-delivery tracking, and an application-stage summary view. The Go
backend now includes a Resend HTTP client and responsive, escaped HTML plus
plain-text aptitude/interview invitation templates. They are **not yet wired
to a transactional outbox worker or invitation workflow**; recorded emails
remain manual-delivery records and no email is automatically sent. Coding
submissions remain unevaluated until a trusted runner is added. Candidate
interview invitation links, expiry/revocation management, the interview
placeholder route, and automatic aptitude-to-interview progression are not
implemented. Recruiter decisions remain human decisions.

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
server-only privileged credential for aptitude candidate sessions, invitations,
answer autosave, and scoring; the credential is never sent to the browser.
Recruiter assessment reads and reprocess requests use Supabase authentication
and RLS.

The backend verifies access tokens against Supabase Auth. Its existing endpoints are:

- `GET /api/health` — backend health.
- `GET /api/v1/me` — authenticated user ID only.
- `GET /api/v1/workspace-access?workspace_id=<uuid>` — the authenticated
  member's workspace role.
- `POST /api/v1/aptitude/invitations` — recruiter-authorized invitation link
  creation; email delivery is manual.
- `POST /api/v1/aptitude/candidate/session`
- `POST /api/v1/aptitude/candidate/start`
- `POST /api/v1/aptitude/candidate/answer`
- `POST /api/v1/aptitude/candidate/submit`
- `POST /api/v1/aptitude/candidate/event` — token-mediated public candidate
  endpoints. Tokens are hashed before database access; answer keys remain in
  the private schema and are only used by server-side scoring.

Workspace access is queried with the caller's token, so Supabase RLS remains
active. The recruiter screening page reads persisted job-specific assessments
and can request processing/retry through permission-checked database functions.
The aptitude workspace provides test/version authoring, publishing, manual
invitation links, autosaved candidate sessions, event notice/monitoring, and
server-calculated results. Passing a configured aptitude threshold is only a
recruiter-facing recommendation; no application stage changes automatically.
The Vite development server proxies `/api` requests to `http://127.0.0.1:8080`;
run the Go server alongside `npm run dev`. Configure the server-only
`SUPABASE_SECRET_KEY` (or legacy `SUPABASE_SERVICE_ROLE_KEY`) for aptitude
endpoints and the worker.

### Resend setup (owner action)

Email templates and a provider client are implemented, but automatic delivery,
outbox processing, provider webhooks, and delivery-status reconciliation are
not yet connected. Do not configure production sends based on this scaffold.
When the delivery workflow is completed, the project owner must:

1. Create an account at [Resend](https://resend.com/) and generate an API key
   with email-send access.
2. Add and verify a sending domain under **Domains**. Publish the exact SPF and
   DKIM DNS records Resend displays; configure DMARC for the domain's policy.
3. Configure `EMAIL_FROM_ADDRESS` using the verified domain and set
   `EMAIL_FROM_NAME=ProofHire`.
4. Store `EMAIL_API_KEY`, sender settings, and `APP_BASE_URL` only in the
   backend/worker secret environment (never in Vite variables or Git). Copy
   `.env.backend.example` and fill the values in the deployment's secret
   manager; do not paste credentials into chat.
5. In Resend **Webhooks**, register the deployed API webhook URL and select
   delivery, bounce, and complaint events. Webhook signature verification is
   not implemented yet, so do not enable this workflow until it is.
6. After the outbox and webhook code is deployed, send a controlled message to
   an address you control and verify provider acceptance, delivery, and bounce
   events in both Resend and the recruiter dashboard.

Resend may allow testing from its onboarding/sandbox sender before a domain is
verified, with restrictions on permitted recipients and sender identity.
Consult the current Resend dashboard and documentation for the account-specific
limits; this repository has not tested an actual Resend account or delivered
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
sessions and a server-only privileged credential for aptitude session RPCs.
The isolated screening worker uses that same privileged credential and must be
deployed as a protected server process, not in the browser or a static Vite
bundle.

Database migrations are in `supabase/migrations/`; read
[`supabase/database-architecture.md`](supabase/database-architecture.md) for the
repository audit, schema relationships, RLS rules, and safe test setup. The
screening, aptitude, resume-version, recruitment-foundation, coding, email, and
deterministic-screening-configuration migrations are additive and have **not**
been verified as applied to any database.
Verify the target is a disposable local/test database before applying them;
never run a local reset or migration command against production. The resume
bucket must remain private. Do not grant anonymous users direct
candidate/application/assessment table permissions.

The screening engine performs exact phrase and structured experience matching
locally. Scores include unmatched requirements in the denominator; partial
matches receive half weight. Absence of a resume phrase is recorded as missing
evidence, not proof the candidate lacks a qualification. Explicitly stated
absence can be marked not met only where the resume says so directly. No live
Supabase RLS check or full database integration test was possible because the
configured Supabase API returned HTTP 401. Recruiter job settings and
requirements must be saved after the reviewed migration is applied; changing
them queues screening again. Existing application records without a stored
resume cannot be reconstructed from their candidate record; recruiters must
attach the original document to that application before screening. Screening
results are advisory: authorized recruiters make and audit application-stage
decisions separately.

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
