# Matrix (matrixf)

Flutter learning platform (courses, text modules, reader, AI tutor) on a Supabase backend.

**Status: mid-rebuild.** The target architecture and the phase-by-phase plan are in
[`docs/REBUILD_PLAN.md`](docs/REBUILD_PLAN.md).

## Current layout

| Path | What it is |
|---|---|
| `lib/` | The Flutter app (learner and admin together; admin is split out in phase P3) |
| `courses/`, `scripts/`, `.github/workflows/` | Markdown course content and the GitHub Action that syncs it to Supabase |
| `android/`, `ios/`, `web/` | Platform folders (desktop platforms were removed) |
| `docs/` | Plan and archived design notes |

## Run

```
flutter pub get
flutter run --dart-define=GEMINI_API_KEY=<key>
```

`SUPABASE_URL` and `SUPABASE_ANON_KEY` can also be passed with `--dart-define`;
the defaults are in `lib/src/api.dart`.

> `GEMINI_API_KEY` is currently compiled into the client. Phase P4 moves it behind
> a Supabase Edge Function.
