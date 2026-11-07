# Rebuild plan

Goal: turn the current single Flutter app into a production-ready system with a
separate admin web app, a learner app (Android + web), and a backend defined in code.

## Decisions

- Admin becomes its own Flutter **web** app in its own folder; the learner app keeps no admin code.
- Learner app ships as Android (Play Store first) and a web PWA from one codebase; iOS later.
- The local `ai_server` (Python/Ollama) is **deleted**, together with the Flutter screens that only drove it.
- Fresh clean git repo (old repo renamed `matrix-legacy` and archived).
- Supabase: restore the paused project, dump its schema, then rebuild it from migrations.
- Payments: Razorpay is planned but not set up. Not part of P0-P3.

## Target layout

```
matrix/
  apps/learner/          Flutter: Android + iOS + web
  apps/admin/            Flutter web, admin only
  packages/matrix_core/  models, auth, repositories, text renderer
  supabase/              migrations (schema + RLS), edge functions
  tools/course-sync/     markdown -> Supabase sync script
  content/courses/       course markdown
  docs/
```

## Phases

| Phase | Goal | Verified by |
|---|---|---|
| P0 Safety net | Tag the old state, restore Supabase, dump schema and data | Dump files exist; project responds |
| P1 Clean-up | Remove the AI server and junk, archive roadmap docs, real README, fresh repo | `flutter analyze` and the app runs as before |
| P2 Core + workspace | Create `matrix_core`; replace the hand-written `dart:io` HTTP/auth layer with `supabase_flutter`; add `go_router` | Android app behaves identically |
| P3 Admin split | New `apps/admin` (Flutter web); remove admin code from the learner app; server-side role check | Learner has no admin code; admin works in a browser |
| P4 Backend as code | `supabase/migrations` with RLS based on `is_admin()`; Edge Functions for AI; remove the Gemini key from the client and rotate it | Non-admin writes are rejected; AI works with no key in the client |
| P5 Learner web | Remove `dart:io` and `Image.file` usage, web OAuth, deploy as PWA | Opens in a browser; deep links work |
| P6 Production | Final app name/ID/domain, release keystore, iOS URL scheme, CI, env config, store requirements | Signed AAB installs; CI green |

## Open items

- **Razorpay:** before designing checkout, check Google Play's current rules for selling digital content
  inside an Android app. The result decides whether payment happens in-app or on the web.
- **Names:** final app name, application ID and domain are needed by P6.
- **Reader themes:** `lib/src/screens/reading_settings.dart` is finished but not wired in; kept for now.

## How changes are delivered

One patch zip per phase. Each zip contains an `apply.ps1` that checks the repo state first and aborts
on any mismatch, plus verify steps. Work happens on a branch; `main` is untouched until a phase is verified.
