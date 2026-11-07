#!/usr/bin/env node
/**
 * Parses and syncs course subject .md files into Supabase.
 *
 * File convention:
 *   - File name (minus .md) = the course's `slug` in Supabase. The course
 *     row itself must already exist (created manually) — this script only
 *     ever reads `courses`, never creates or edits one.
 *   - Modules start with a heading like:
 *       ## Module 1: Introduction to PLCs
 *     The number becomes `display_order`; anything after the colon becomes
 *     `title` (optional — falls back to "Module N").
 *   - Inside a module, an optional
 *       ### Q&A
 *     heading starts that module's Q&A section, formatted as:
 *       Q: question text
 *       A: answer text (can wrap onto following lines)
 *     Everything before "### Q&A" is the module's body content; everything
 *     after it (until the next "## Module") is Q&A only, and is NOT written
 *     into module_text_versions.content.
 *
 * Modes (pick one):
 *   (default)              Real sync — writes to Supabase.
 *   --dry-run              Never writes. With Supabase credentials present,
 *                          reads real state and reports exactly what a real
 *                          run would do. Without credentials, runs "offline"
 *                          — parsing/validation only (duplicate module
 *                          numbers, invalid [IMG:] tokens, missing modules).
 *   --revert <slug> <module-order> <version>
 *                          Restores a module's content from an older
 *                          version, written forward as a new version (so
 *                          history stays intact). Combine with --dry-run to
 *                          preview without writing. Always needs Supabase
 *                          credentials — there is no offline revert.
 *   --preview [file...]    Renders an approximate local HTML preview of
 *                          each given file next to it (foo.md ->
 *                          foo.preview.html). Fully offline, no Supabase
 *                          needed — just a visual sanity check of markdown
 *                          structure, headings, tables, image-token
 *                          placeholders and Q&A, NOT a pixel-exact copy of
 *                          the app's own renderer.
 *
 * File selection (sync mode only):
 *   - Positional CLI args, if given, are used as the file list (for local
 *     runs), e.g.  node scripts/sync-course-modules.js --dry-run courses/pbect205.md
 *   - Otherwise falls back to the CHANGED_FILES env var (newline-separated
 *     paths), which is how the GitHub Actions workflows call this script.
 *
 * Required env vars for anything that touches Supabase:
 *   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
 */

const fs = require('fs');
const path = require('path');

// ---------- CLI parsing ----------
function parseArgs(argv) {
  const dryRun = argv.includes('--dry-run');
  const revertIdx = argv.indexOf('--revert');
  const previewIdx = argv.indexOf('--preview');

  if (revertIdx !== -1) {
    const [slug, orderStr, versionStr] = argv.slice(revertIdx + 1, revertIdx + 4);
    return {
      mode: 'revert',
      dryRun,
      slug,
      order: parseInt(orderStr, 10),
      version: parseInt(versionStr, 10),
    };
  }
  if (previewIdx !== -1) {
    const files = argv.slice(previewIdx + 1).filter((a) => !a.startsWith('--'));
    return { mode: 'preview', dryRun, files };
  }
  const files = argv.filter((a) => !a.startsWith('--'));
  return { mode: 'sync', dryRun, files };
}

const args = parseArgs(process.argv.slice(2));

const SUPABASE_URL = process.env.SUPABASE_URL;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const REMOTE = Boolean(SUPABASE_URL && SERVICE_KEY);

// ---------- Supabase REST helper ----------
const baseHeaders = REMOTE
  ? {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'application/json',
    }
  : null;

async function sb(pathAndQuery, opts = {}) {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/${pathAndQuery}`, {
    method: opts.method || 'GET',
    headers: { ...baseHeaders, Prefer: opts.prefer || 'return=representation' },
    body: opts.body,
  });
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`${opts.method || 'GET'} ${pathAndQuery} -> ${res.status}: ${text}`);
  }
  const text = await res.text();
  return text ? JSON.parse(text) : null;
}

// ---------- tiny Levenshtein, for "did you mean" on a missing slug ----------
function levenshtein(a, b) {
  const dp = Array.from({ length: a.length + 1 }, () => new Array(b.length + 1).fill(0));
  for (let i = 0; i <= a.length; i++) dp[i][0] = i;
  for (let j = 0; j <= b.length; j++) dp[0][j] = j;
  for (let i = 1; i <= a.length; i++) {
    for (let j = 1; j <= b.length; j++) {
      dp[i][j] =
        a[i - 1] === b[j - 1]
          ? dp[i - 1][j - 1]
          : 1 + Math.min(dp[i - 1][j - 1], dp[i - 1][j], dp[i][j - 1]);
    }
  }
  return dp[a.length][b.length];
}

async function closestSlugSuggestion(slug) {
  if (!REMOTE) return null;
  try {
    const all = await sb('courses?select=slug');
    if (!all || all.length === 0) return null;
    let best = null;
    for (const c of all) {
      const d = levenshtein(slug, c.slug);
      if (!best || d < best.d) best = { slug: c.slug, d };
    }
    return best && best.d <= 3 ? best.slug : null;
  } catch {
    return null;
  }
}

// ---------- parsing ----------
const MODULE_HEADING = /^##\s*module\s+(\d+)\s*:?\s*(.*)$/i;
const QA_HEADING = /^###\s*q\s*&?\s*a\s*$/i;
const IMG_TOKEN = /\[(img|gif):\s*([^\]\(]+?)\s*(?:\(|\])/gi;

function normalizeLineEndings(raw) {
  return raw.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
}

function findInvalidImageTokens(text) {
  const bad = [];
  let m;
  IMG_TOKEN.lastIndex = 0;
  while ((m = IMG_TOKEN.exec(text))) {
    const key = m[2].trim();
    if (!/^[a-z0-9_]+$/.test(key)) bad.push(key);
  }
  return bad;
}

function parseQA(lines) {
  const pairs = [];
  let question = null;
  let answerLines = [];
  const flush = () => {
    if (question !== null) {
      const answer = answerLines.join('\n').trim();
      if (question.trim() && answer) pairs.push({ question: question.trim(), answer });
    }
    question = null;
    answerLines = [];
  };
  for (const line of lines) {
    const q = line.match(/^Q:\s*(.*)$/i);
    const a = line.match(/^A:\s*(.*)$/i);
    if (q) {
      flush();
      question = q[1];
    } else if (a && question !== null) {
      answerLines.push(a[1]);
    } else if (question !== null) {
      answerLines.push(line);
    }
  }
  flush();
  return pairs;
}

function parseFile(raw) {
  const lines = normalizeLineEndings(raw).split('\n');
  const rawModules = [];
  let current = null;
  let inQA = false;

  for (const line of lines) {
    const mod = line.match(MODULE_HEADING);
    if (mod) {
      if (current) rawModules.push(current);
      current = { order: parseInt(mod[1], 10), title: mod[2].trim(), body: [], qa: [] };
      inQA = false;
      continue;
    }
    if (!current) continue; // ignore any preamble before the first "## Module"
    if (!inQA && QA_HEADING.test(line)) {
      inQA = true;
      continue;
    }
    if (inQA) current.qa.push(line);
    else current.body.push(line);
  }
  if (current) rawModules.push(current);

  const errors = [];
  const seenOrders = new Set();
  for (const m of rawModules) {
    if (seenOrders.has(m.order)) errors.push(`duplicate "Module ${m.order}" heading`);
    seenOrders.add(m.order);
  }

  const modules = rawModules.map((m) => {
    const content = m.body.join('\n').trim();
    const qaPairs = parseQA(m.qa);
    const badTokens = findInvalidImageTokens(content);
    if (badTokens.length > 0) {
      errors.push(
        `Module ${m.order}: invalid image token(s) ${badTokens
          .map((t) => `"${t}"`)
          .join(', ')} — must match ^[a-z0-9_]+$`
      );
    }
    return { order: m.order, title: m.title || `Module ${m.order}`, content, qaPairs };
  });

  return { modules, errors };
}

// ---------- SYNC mode ----------
async function processModule(slug, courseId, mod, dryRun) {
  const label = `${slug} — Module ${mod.order}: ${mod.title}`;

  if (!REMOTE) {
    console.log(`[offline] ${label} — ${mod.content.length} chars, ${mod.qaPairs.length} Q&A pair(s)`);
    return;
  }

  const existing = await sb(
    `modules?course_id=eq.${courseId}&display_order=eq.${mod.order}&select=id,title`
  );
  let moduleRow = existing && existing[0];
  const isNewModule = !moduleRow;

  if (!dryRun) {
    if (isNewModule) {
      const created = await sb('modules', {
        method: 'POST',
        body: JSON.stringify({
          course_id: courseId,
          title: mod.title,
          display_order: mod.order,
          module_type: 'text',
        }),
      });
      moduleRow = created[0];
      console.log(`[new module] ${label}`);
    } else if (mod.title && moduleRow.title !== mod.title) {
      await sb(`modules?id=eq.${moduleRow.id}`, {
        method: 'PATCH',
        body: JSON.stringify({ title: mod.title }),
        prefer: 'return=minimal',
      });
    }
  }

  let latestContent = null;
  let nextVersion = 1;
  if (!isNewModule) {
    const latest = await sb(
      `module_text_versions?module_id=eq.${moduleRow.id}&is_latest=eq.true&select=version,content&limit=1`
    );
    if (latest && latest.length > 0) {
      latestContent = latest[0].content;
      nextVersion = latest[0].version + 1;
    }
  }
  const unchanged = latestContent !== null && latestContent.trim() === mod.content.trim();

  let existingQACount = 0;
  if (!isNewModule) {
    const qaRows = await sb(`module_qa?module_id=eq.${moduleRow.id}&select=id`);
    existingQACount = qaRows ? qaRows.length : 0;
  }

  if (dryRun) {
    console.log(`[dry-run] ${label}`);
    console.log(`    module: ${isNewModule ? 'NEW (would create)' : 'exists'}`);
    console.log(
      `    content: ${
        unchanged ? `unchanged from v${nextVersion - 1} — would skip new version` : `would insert v${nextVersion}`
      }`
    );
    console.log(
      `    Q&A: ${mod.qaPairs.length} pair(s) in file (would replace ${existingQACount} existing row(s))`
    );
    return;
  }

  if (unchanged) {
    console.log(`[unchanged] ${label} — content matches v${nextVersion - 1}, skipping new version`);
  } else {
    await sb(`module_text_versions?module_id=eq.${moduleRow.id}&is_latest=eq.true`, {
      method: 'PATCH',
      body: JSON.stringify({ is_latest: false }),
      prefer: 'return=minimal',
    });
    await sb('module_text_versions', {
      method: 'POST',
      body: JSON.stringify({
        module_id: moduleRow.id,
        version: nextVersion,
        content: mod.content,
        is_latest: true,
      }),
      prefer: 'return=minimal',
    });
    console.log(`[synced] ${label} -> version ${nextVersion}`);
  }

  // Q&A: the file is the full source of truth for this module — replace-all.
  await sb(`module_qa?module_id=eq.${moduleRow.id}`, { method: 'DELETE', prefer: 'return=minimal' });
  if (mod.qaPairs.length > 0) {
    await sb('module_qa', {
      method: 'POST',
      body: JSON.stringify(
        mod.qaPairs.map((p, i) => ({
          module_id: moduleRow.id,
          question: p.question,
          answer_text: p.answer,
          display_order: i + 1,
        }))
      ),
      prefer: 'return=minimal',
    });
  }
  console.log(`    Q&A: ${mod.qaPairs.length} pair(s) written`);
}

async function processFile(filePath, dryRun) {
  const slug = path.basename(filePath, '.md').toLowerCase();

  if (!fs.existsSync(filePath)) {
    console.log(`[skip] ${filePath}: deleted, not syncing.`);
    return { ok: true, slug };
  }

  const raw = fs.readFileSync(filePath, 'utf8');
  const { modules, errors } = parseFile(raw);

  if (modules.length === 0) errors.unshift('no "## Module N" headings found');

  if (errors.length > 0) {
    console.error(`[invalid] ${filePath}:`);
    for (const e of errors) console.error(`    - ${e}`);
    return { ok: false, slug };
  }

  let courseId = null;
  if (REMOTE) {
    const courses = await sb(`courses?slug=eq.${encodeURIComponent(slug)}&select=id,slug`);
    if (!courses || courses.length === 0) {
      const suggestion = await closestSlugSuggestion(slug);
      console.warn(
        `[skip] ${filePath}: no course with slug "${slug}" in Supabase.${
          suggestion ? ` Did you mean "${suggestion}"?` : ' Create it manually first.'
        }`
      );
      return { ok: false, slug };
    }
    courseId = courses[0].id;
  } else {
    console.log(`[offline] ${filePath}: skipping course/version lookups (no Supabase credentials).`);
  }

  for (const mod of modules) {
    await processModule(slug, courseId, mod, dryRun);
  }

  return { ok: true, slug };
}

async function runSync({ dryRun, files: cliFiles }) {
  if (!REMOTE && !dryRun) {
    console.error(
      'Missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY (required for a real sync).\n' +
        'Add --dry-run to validate locally without them.'
    );
    process.exit(1);
  }

  const files = (cliFiles.length > 0 ? cliFiles : (process.env.CHANGED_FILES || '').split('\n'))
    .map((f) => f.trim())
    .filter((f) => f.length > 0 && f.toLowerCase().endsWith('.md'))
    .filter((f) => path.basename(f).toLowerCase() !== 'readme.md');

  if (files.length === 0) {
    console.log('No .md files to process.');
    return;
  }

  if (dryRun) {
    console.log(
      REMOTE
        ? '--- DRY RUN (checking against live Supabase, no writes) ---\n'
        : '--- DRY RUN (offline — no Supabase credentials, format checks only) ---\n'
    );
  }

  const results = [];
  for (const file of files) {
    try {
      results.push(await processFile(file, dryRun));
    } catch (err) {
      console.error(`[error] ${file}: ${err.message}`);
      results.push({ ok: false, slug: file });
    }
  }

  const failed = results.filter((r) => !r.ok);
  console.log(`\n${results.length - failed.length}/${results.length} file(s) ${dryRun ? 'valid' : 'synced'}.`);
  if (failed.length > 0) {
    console.error(`${failed.length} file(s) had problems — see above.`);
    process.exit(1);
  }
}

// ---------- REVERT mode ----------
async function runRevert({ slug, order, version, dryRun }) {
  if (!REMOTE) {
    console.error('--revert needs SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY — there is no offline revert.');
    process.exit(1);
  }
  if (!slug || !Number.isInteger(order) || !Number.isInteger(version)) {
    console.error('Usage: node scripts/sync-course-modules.js --revert <course-slug> <module-order> <version-to-restore>');
    process.exit(1);
  }

  const courses = await sb(`courses?slug=eq.${encodeURIComponent(slug)}&select=id`);
  if (!courses || courses.length === 0) {
    console.error(`No course with slug "${slug}".`);
    process.exit(1);
  }
  const courseId = courses[0].id;

  const modules = await sb(`modules?course_id=eq.${courseId}&display_order=eq.${order}&select=id,title`);
  if (!modules || modules.length === 0) {
    console.error(`No Module ${order} found for course "${slug}".`);
    process.exit(1);
  }
  const moduleId = modules[0].id;

  const target = await sb(`module_text_versions?module_id=eq.${moduleId}&version=eq.${version}&select=content`);
  if (!target || target.length === 0) {
    console.error(`Module ${order} of "${slug}" has no version ${version} to restore.`);
    process.exit(1);
  }
  const targetContent = target[0].content;

  const latest = await sb(
    `module_text_versions?module_id=eq.${moduleId}&select=version&order=version.desc&limit=1`
  );
  const currentVersion = latest && latest[0] ? latest[0].version : 0;
  const nextVersion = currentVersion + 1;

  if (dryRun) {
    console.log(
      `[dry-run revert] ${slug} — Module ${order}: would restore content from v${version} as new v${nextVersion} (current latest: v${currentVersion})`
    );
    return;
  }

  await sb(`module_text_versions?module_id=eq.${moduleId}&is_latest=eq.true`, {
    method: 'PATCH',
    body: JSON.stringify({ is_latest: false }),
    prefer: 'return=minimal',
  });
  await sb('module_text_versions', {
    method: 'POST',
    body: JSON.stringify({ module_id: moduleId, version: nextVersion, content: targetContent, is_latest: true }),
    prefer: 'return=minimal',
  });

  console.log(`[reverted] ${slug} — Module ${order}: restored content from v${version} as new v${nextVersion}`);
}

// ---------- PREVIEW mode ----------
function escapeHtml(s) {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}

function renderInline(text) {
  let out = escapeHtml(text);
  out = out.replace(/\*\*(.+?)\*\*/g, '<strong>$1</strong>');
  out = out.replace(/(?<!\*)\*([^*]+?)\*(?!\*)/g, '<em>$1</em>');
  out = out.replace(
    /\[(img|gif):\s*([^\]\(]+?)\s*(?:\(([^)]*)\))?\]/gi,
    (_m, kind, key, desc) =>
      `<div class="img-placeholder">Image placeholder — ${kind.toUpperCase()}: <code>${escapeHtml(
        key.trim()
      )}</code>${desc ? ` — ${escapeHtml(desc)}` : ''}</div>`
  );
  return out;
}

function renderBody(content) {
  const lines = content.split('\n');
  let html = '';
  let inList = false;
  let tableRows = [];
  let inTable = false;

  const closeList = () => {
    if (inList) {
      html += '</ul>\n';
      inList = false;
    }
  };
  const flushTable = () => {
    if (tableRows.length === 0) return;
    const rows = tableRows.filter((r) => !r.every((c) => /^\s*-+\s*$/.test(c)));
    const [headerRow, ...bodyRows] = rows;
    html += '<table><thead><tr>';
    for (const c of headerRow) html += `<th>${renderInline(c.trim())}</th>`;
    html += '</tr></thead><tbody>';
    for (const row of bodyRows) {
      html += '<tr>';
      for (const c of row) html += `<td>${renderInline(c.trim())}</td>`;
      html += '</tr>';
    }
    html += '</tbody></table>\n';
    tableRows = [];
    inTable = false;
  };

  for (const line of lines) {
    const h3 = line.match(/^###\s+(.*)$/);
    const h2 = line.match(/^##\s+(.*)$/);
    const h1 = line.match(/^#\s+(.*)$/);
    const li = line.match(/^[-*]\s+(.*)$/);
    const tableRow = line.match(/^\s*\|(.+)\|\s*$/);

    if (tableRow) {
      inTable = true;
      tableRows.push(tableRow[1].split('|'));
      continue;
    } else if (inTable) {
      flushTable();
    }

    if (h3) {
      closeList();
      html += `<h3>${renderInline(h3[1])}</h3>\n`;
    } else if (h2) {
      closeList();
      html += `<h2>${renderInline(h2[1])}</h2>\n`;
    } else if (h1) {
      closeList();
      html += `<h1>${renderInline(h1[1])}</h1>\n`;
    } else if (li) {
      if (!inList) {
        html += '<ul>\n';
        inList = true;
      }
      html += `<li>${renderInline(li[1])}</li>\n`;
    } else if (line.trim() === '') {
      closeList();
    } else {
      closeList();
      html += `<p>${renderInline(line)}</p>\n`;
    }
  }
  closeList();
  flushTable();
  return html;
}

function renderPreviewHtml(slug, modules) {
  const moduleHtml = modules
    .map((m) => {
      const qaHtml =
        m.qaPairs.length > 0
          ? `<div class="qa"><h4>Q&amp;A</h4>${m.qaPairs
              .map(
                (p) =>
                  `<div class="qa-pair"><p class="q">Q: ${renderInline(p.question)}</p><p class="a">A: ${renderInline(
                    p.answer
                  )}</p></div>`
              )
              .join('')}</div>`
          : '';
      return `<section class="module"><h2>Module ${m.order}: ${escapeHtml(m.title)}</h2>${renderBody(
        m.content
      )}${qaHtml}</section>`;
    })
    .join('\n');

  return `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${escapeHtml(slug)} — preview</title>
<script src="https://cdnjs.cloudflare.com/ajax/libs/mathjax/3.2.2/es5/tex-mml-chtml.min.js"></script>
<style>
  body { font-family: -apple-system, Segoe UI, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; line-height: 1.55; color: #1a1a1a; }
  h1, h2, h3 { line-height: 1.25; }
  .module { border-top: 2px solid #e2e2e2; padding-top: 1.5rem; margin-top: 2rem; }
  .img-placeholder { border: 1px dashed #999; border-radius: 6px; padding: 0.75rem 1rem; margin: 0.75rem 0; background: #f7f7f7; font-size: 0.9rem; color: #555; }
  table { border-collapse: collapse; margin: 1rem 0; }
  th, td { border: 1px solid #ccc; padding: 0.4rem 0.7rem; text-align: left; }
  .qa { margin-top: 1.25rem; background: #f2f6ff; border-radius: 8px; padding: 1rem 1.25rem; }
  .qa-pair { margin-bottom: 0.75rem; }
  .q { font-weight: 600; margin: 0 0 0.15rem; }
  .a { margin: 0; color: #333; }
  .note { color: #888; font-size: 0.85rem; }
</style>
</head>
<body>
<p class="note">Approximate local preview of "${escapeHtml(slug)}" — structure only, not the exact app renderer.</p>
${moduleHtml}
</body>
</html>`;
}

async function runPreview({ files }) {
  if (files.length === 0) {
    console.error('Usage: node scripts/sync-course-modules.js --preview <file.md> [more.md ...]');
    process.exit(1);
  }
  for (const file of files) {
    if (!fs.existsSync(file)) {
      console.error(`[preview] ${file}: not found.`);
      continue;
    }
    const raw = fs.readFileSync(file, 'utf8');
    const { modules, errors } = parseFile(raw);
    if (errors.length > 0) {
      console.warn(`[preview] ${file}: has validation problems, rendering anyway —`);
      for (const e of errors) console.warn(`    - ${e}`);
    }
    const slug = path.basename(file, '.md').toLowerCase();
    const html = renderPreviewHtml(slug, modules);
    const outPath = file.replace(/\.md$/i, '.preview.html');
    fs.writeFileSync(outPath, html, 'utf8');
    console.log(`[preview] wrote ${outPath}`);
  }
}

// ---------- main ----------
(async () => {
  if (args.mode === 'revert') {
    await runRevert(args);
  } else if (args.mode === 'preview') {
    await runPreview(args);
  } else {
    await runSync(args);
  }
})();
