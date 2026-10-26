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
- Private candidate resume storage and recruiter-only resume access.
- Manual recruiter decisions and internal interview scheduling, outcomes, and
  feedback.
- Workspace-scoped CSV, PDF, and XLSX exports. Exports do not contain private
  resume paths or signed URLs.

Resume parsing, persisted screening assessments, AI recommendations,
automated email invitations, candidate interview sessions, recording,
transcription, and AI interview evaluations are **not implemented**. External
AI/email/transcription/video providers remain disabled until selected and
configured. Do not interpret recruiter decisions or interview outcomes as AI
assessments.

## Requirements

- Node.js 22 or newer.
- npm.
- A Supabase project configured for ProofHire.

The Go backend foundation includes health and authenticated identity endpoints.
Resume processing and provider integrations are not implemented yet.

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

### Go backend

Install Go 1.23 or newer. Set the server-side `SUPABASE_URL` and
`SUPABASE_ANON_KEY` environment variables in the process environment, then
run the commands below. `.env.backend.example` is a reference only; the Go
server does not load dotenv files automatically.

```powershell
$env:SUPABASE_URL = "https://your-project.supabase.co"
$env:SUPABASE_ANON_KEY = "your-supabase-anon-or-publishable-key"
go test ./...
go run ./backend/cmd/server
```

The backend verifies access tokens against Supabase Auth and does not accept
service-role credentials. Its initial endpoints are:

- `GET /api/health` — backend health.
- `GET /api/v1/me` — authenticated user ID only.
- `GET /api/v1/workspace-access?workspace_id=<uuid>` — the authenticated
  member's workspace role.

Workspace access is queried with the caller's token, so Supabase RLS remains
active. These endpoints are not yet used by the existing frontend and do not
perform recruitment processing.

## Supabase configuration

Required frontend environment variables:

| Variable | Purpose |
| --- | --- |
| `VITE_SUPABASE_URL` | Supabase project URL |
| `VITE_SUPABASE_PUBLISHABLE_KEY` | Supabase publishable key (preferred) |
| `VITE_SUPABASE_ANON_KEY` | Legacy anon key; used if the publishable-key variable is unset |

Only the anon/publishable key belongs in browser configuration. **Never put a
Supabase secret/service-role key or other server secret in a `VITE_` variable.**
The backend currently uses the same anon/publishable key to verify sessions
through Supabase Auth; future privileged server tasks must use a separate,
server-only, least-privilege design.

Database migrations are in `supabase/migrations/`. A migration file in this
repository does not prove that the migration is applied to a deployed project.
Review and apply migrations through the approved Supabase workflow, in order,
after checking the target database. The resume bucket is intended to remain
private. Do not grant anonymous users direct candidate/application table
permissions to enable public applications.

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
   `SUPABASE_URL` and `SUPABASE_ANON_KEY` for the Go function as well; these
   are server-side environment variables and must not use the `VITE_` prefix.
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
