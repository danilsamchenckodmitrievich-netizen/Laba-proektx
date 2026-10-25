-- Заглушка Supabase Storage для локальной базы: таблицы buckets и objects, как в Supabase.
create schema if not exists storage;
create table if not exists storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, metadata jsonb,
  created_at timestamptz default now(), unique(bucket_id, name));
alter table storage.objects enable row level security;
grant usage on schema storage to anon;
grant select, insert, delete on storage.objects to anon;
grant select on storage.buckets to anon;
