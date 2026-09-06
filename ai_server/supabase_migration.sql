-- ============================================================
-- MatrixF: AI Course Generation — Supabase migration
-- Run this once in the Supabase SQL Editor.
-- ============================================================

-- ── Table: course_generation_jobs ─────────────────────────────────────────────
-- Tracks each AI generation request.
-- status:  pending → processing → done | failed
-- mode:    create (new content) | enhance (extend existing module)

create table if not exists course_generation_jobs (
  id               uuid primary key default gen_random_uuid(),
  course_id        uuid references courses(id) on delete set null,
  status           text not null default 'pending',
  source_file_urls text[] not null default '{}',
  mode             text not null default 'create',
  error_message    text,
  raw_generated_text text,      -- stored WITH [img:...] tokens intact
  created_at       timestamptz not null default now()
);

-- Index for querying jobs by course
create index if not exists idx_gen_jobs_course_id
  on course_generation_jobs (course_id);

-- ── Table: course_image_tokens ────────────────────────────────────────────────
-- Tracks each [img:{id}|{title}|{desc}] placeholder emitted by the AI.
-- image_url is null until the admin uploads the real figure/diagram.

create table if not exists course_image_tokens (
  id           text primary key,                                   -- e.g. "fig1.1"
  course_id    uuid references courses(id)  on delete cascade,
  module_id    uuid references modules(id)  on delete cascade,
  short_title  text,
  description  text,
  image_url    text,            -- null = not yet filled by admin
  created_at   timestamptz not null default now()
);

-- Index for querying tokens by module
create index if not exists idx_img_tokens_module_id
  on course_image_tokens (module_id);

-- Index for querying unfilled tokens
create index if not exists idx_img_tokens_unfilled
  on course_image_tokens (course_id)
  where image_url is null;

-- ── Notes ─────────────────────────────────────────────────────────────────────
-- Generated content is stored in module_text_versions.content WITH [img:...] 
-- tokens intact (not stripped). The Flutter renderer substitutes them at
-- display time using the course_image_tokens / course_images tables.
--
-- RLS: Add policies matching your existing tables if RLS is enabled.
-- Example (admin-only write, public read):
--
-- alter table course_image_tokens enable row level security;
-- create policy "Admin write" on course_image_tokens
--   for all using (auth.role() = 'authenticated')
--   with check (auth.role() = 'authenticated');
-- create policy "Public read" on course_image_tokens
--   for select using (true);
