P1 CLEAN-UP PATCH  (built against commit 7de2328 of matrix/main)
==================================================================

WHAT IT DOES
  - Deletes the AI server: ai_server/ (13 files), ai_server.zip, and the 4 Flutter
    files that only drove it (ai_course_create_screen, ai_course_review_screen,
    course_generation_service, models/course_generation_job).
  - Removes the "AI Generate Course" button from the admin hub (admin_screen.dart)
    and adminUpsertCourseImageToken from api.dart.  Exact changes: review\*.diff
  - Deletes junk: fix_imports.dart, rename_widgets.dart, split_app.dart, update.ps1,
    test.dart, dummy.jpg, .blackboxrules, linux/, macos/, windows/, and the
    unreferenced lib files gemini_image_api.dart and theme/spacing.dart.
  - Moves the 8 roadmap notes to docs/archive/ (names cleaned up).
  - Adds a real README.md and docs/REBUILD_PLAN.md.
  - KEPT on purpose: AI Reindex, the image Upload screen, reading_settings.dart.
  - Everything happens on a NEW branch (rebuild/p1-cleanup). main is not touched.

STEP 0 - BASELINE (on main, before applying)
  cd C:\Users\ABHIJITH\matrixf
  flutter pub get
  flutter analyze        -> note the number of issues it reports

STEP 1 - APPLY
  Unzip this folder anywhere, e.g. C:\Users\ABHIJITH\p1-cleanup, then from the repo root:
  powershell -ExecutionPolicy Bypass -File C:\Users\ABHIJITH\p1-cleanup\apply.ps1

  The script checks, before changing anything, that HEAD is 7de2328, the working
  tree is clean, and the two edited files match what I read.  If any check fails it
  stops and changes nothing - send me the message it prints.
  It also creates a local tag "pre-rebuild" (push it: git push origin pre-rebuild).

STEP 2 - VERIFY
  flutter pub get
  flutter analyze        -> should report no NEW issues vs. your baseline
  flutter test
  flutter run
  In the running app check:
    1. Home / Catalog / Library / Profile open normally
    2. Sign in as admin -> Profile -> Admin: hub opens, the icon row now shows only
       Banners, Upload and AI Reindex (no AI Generate Course button)
    3. Banners, Upload and AI Reindex each open
    4. The AI tutor chat button still opens

STEP 3 - REPORT BACK
  Send me: the analyze count before/after, test result, and anything that failed.
  (I could not run Flutter here, so analyze/test/run are the real verification.)

ROLL BACK (if anything is wrong)
  git checkout main
  git branch -D rebuild/p1-cleanup

NOT YET - only after Step 2 passes (I will confirm before you do this)
  Moving to a fresh clean repo (rename the old one to matrix-legacy, push the cleaned tree).

NOTE
  pubspec.yaml is untouched. file_picker is now unused (and flutter_web_auth_2 already
  was); P2 rewrites pubspec and drops unused packages.
