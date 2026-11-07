<#
  P1 clean-up patch.
  Run from the repo root (the folder with .git and pubspec.yaml):
    powershell -ExecutionPolicy Bypass -File <path-to>\apply.ps1
  Works on a new branch; main is not touched.
#>
$ErrorActionPreference = 'Continue'

$ExpectedHead = '7de2328'
$Branch       = 'rebuild/p1-cleanup'
$Here         = Split-Path -Parent $MyInvocation.MyCommand.Path
$Payload      = Join-Path $Here 'files'

function Fail([string]$msg) { Write-Host "ABORT: $msg" -ForegroundColor Red; exit 1 }
function Info([string]$msg) { Write-Host $msg -ForegroundColor Cyan }
function Invoke-Git { & git @args; if ($LASTEXITCODE -ne 0) { Fail "git $($args -join ' ') failed" } }

function Get-NormHash([string]$path) {
  $text  = [System.IO.File]::ReadAllText($path)
  $text  = $text.Replace("`r`n", "`n")
  $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($text)
  $sha   = [System.Security.Cryptography.SHA256]::Create()
  return (($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '')
}

# ---------- 1. Pre-flight checks (nothing is changed until all pass) ----------
if (-not (Test-Path '.git') -or -not (Test-Path 'pubspec.yaml')) {
  Fail 'Run this from the repo root (the folder that contains .git and pubspec.yaml).'
}
$head = (& git rev-parse --short=7 HEAD).Trim()
if ($head -ne $ExpectedHead) {
  Fail "HEAD is $head but this patch was built for $ExpectedHead. Do not apply it; tell Claude."
}
$dirty = & git status --porcelain
if ($dirty) { Fail ("Working tree is not clean. Commit or stash first:`n" + ($dirty -join "`n")) }

$expectedHashes = @{
  'lib/src/api.dart'                  = '353b711285ce13b37dc48d17cd06f5f76cda538d9f58cec130908f1280c56a9b'
  'lib/src/screens/admin_screen.dart' = '33b976fe4f917bf2f2d2c978c166db5c3e81717b8ac8a66efa4e579e3804e7a9'
}
foreach ($k in $expectedHashes.Keys) {
  if (-not (Test-Path $k)) { Fail "Missing file: $k" }
  if ((Get-NormHash $k) -ne $expectedHashes[$k]) {
    Fail "$k differs from the version this patch was built against. Do not apply it; tell Claude."
  }
}

$payloadFiles = @(
  'README.md',
  'docs/REBUILD_PLAN.md',
  'docs/archive/README.md',
  'lib/src/api.dart',
  'lib/src/screens/admin_screen.dart'
)
foreach ($f in $payloadFiles) {
  if (-not (Test-Path (Join-Path $Payload $f))) { Fail "Patch is incomplete: files/$f is missing." }
}
Info 'Pre-flight checks passed.'

# ---------- 2. Safety tag + branch ----------
if (-not (& git tag --list 'pre-rebuild')) {
  Invoke-Git tag pre-rebuild
  Info 'Created tag pre-rebuild (push it later with: git push origin pre-rebuild).'
}
Invoke-Git checkout -b $Branch

# ---------- 3. Deletions ----------
$deletes = @(
  'ai_server', 'ai_server.zip',
  'lib/src/screens/ai_course_create_screen.dart',
  'lib/src/screens/ai_course_review_screen.dart',
  'lib/src/ai/course_generation_service.dart',
  'lib/src/models/course_generation_job.dart',
  'lib/src/ai/gemini_image_api.dart',
  'lib/src/theme/spacing.dart',
  'fix_imports.dart', 'rename_widgets.dart', 'split_app.dart',
  'update.ps1', 'test.dart', 'dummy.jpg', '.blackboxrules',
  'linux', 'macos', 'windows'
)
foreach ($p in $deletes) {
  if (Test-Path $p) { Invoke-Git rm -r -q --ignore-unmatch $p } else { Write-Host "  (already absent) $p" }
}
# Leftover local-only files (ignored by git, e.g. ai_server\.venv, desktop build output)
foreach ($d in 'ai_server', 'linux', 'macos', 'windows') {
  if (Test-Path $d) {
    $n = (Get-ChildItem $d -Recurse -Force -File | Measure-Object).Count
    Remove-Item $d -Recurse -Force
    Info "Removed leftover local folder '$d' ($n untracked/ignored files)."
  }
}

# ---------- 4. Archive roadmap docs ----------
New-Item -ItemType Directory -Force -Path 'docs/archive' | Out-Null
$moves = @(
  @('AI_CHATBOT_ROADMAP.md',              'docs/archive/ai-chatbot-roadmap.md'),
  @('Ai rag content roadmap .md',         'docs/archive/ai-rag-content-roadmap.md'),
  @('ai_quiz_roadmap.md',                 'docs/archive/ai-quiz-roadmap.md'),
  @('ai_rich_anwsers.md',                 'docs/archive/ai-rich-answers.md'),
  @('inline_image_discription.md',        'docs/archive/inline-image-description.md'),
  @('native_google_signin_roadmap.md',    'docs/archive/native-google-signin-roadmap.md'),
  @('pending_images_roadmap.md',          'docs/archive/pending-images-roadmap.md'),
  @('revison_mode_roadmap.md',            'docs/archive/revision-mode-roadmap.md')
)
foreach ($m in $moves) { Invoke-Git mv $m[0] $m[1] }

# ---------- 5. New / replaced files ----------
foreach ($f in $payloadFiles) {
  $dir = Split-Path $f -Parent
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Copy-Item (Join-Path $Payload $f) $f -Force
}

# ---------- 6. Dangling-reference check ----------
$pattern = 'AiCourseCreateScreen|AiCourseReviewScreen|CourseGenerationService|AiServerSettings|CourseGenerationJob|course_generation_service|course_generation_job|gemini_image_api|GeminiImageApi|AppSpacing|theme/spacing|adminUpsertCourseImageToken'
$hits = Get-ChildItem -Path 'lib','test' -Recurse -Include *.dart | Select-String -Pattern $pattern
if ($hits) {
  Write-Host 'WARNING: leftover references found (tell Claude):' -ForegroundColor Yellow
  $hits | ForEach-Object { Write-Host ("  {0}:{1}  {2}" -f $_.Path, $_.LineNumber, $_.Line.Trim()) }
} else {
  Info 'No dangling references to removed code.'
}

# ---------- 7. Commit on the branch ----------
Invoke-Git add -A
Invoke-Git commit -q -m 'P1: remove AI server and one-off scripts, drop desktop platforms, archive roadmap docs'
Info ''
Info "Done. Changes are committed on branch '$Branch'; main is untouched."
Info 'Next: run the verify steps in README.txt (flutter pub get / analyze / test / run).'
