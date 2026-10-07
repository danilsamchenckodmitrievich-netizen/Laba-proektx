-- Лаборатория Сириус: учебные материалы учителя — ссылки и файлы (презентации, PDF, документы, картинки, видео).
-- Материал прикрепляется ко всему классу, к лабораторной работе или к тесту. Ученики класса видят его после входа по коду.
-- Файлы лежат в хранилище Supabase Storage (bucket «materials», скачивание по ссылке открыто).
-- Загрузка: учитель получает у сервера одноразовое место для файла (t_mat_file), браузер кладёт файл прямо в хранилище,
-- политика хранилища пускает только в такое место, затем t_mat_done отмечает файл готовым.
-- Удаление: t_mat_delete помечает материал удалённым, после этого браузер удаляет сам файл из хранилища.
-- Выполнять после schema.sql и tests.sql.

create table if not exists lab.materials(
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references lab.teachers(id) on delete cascade,
  class_id uuid not null references lab.classes(id) on delete cascade,
  target text not null,
  title text not null,
  kind text not null check (kind in ('link', 'file')),
  url text not null default '',
  path text unique,
  size bigint not null default 0,
  mime text not null default '',
  status text not null default 'ready' check (status in ('pending', 'ready', 'deleted')),
  created_at timestamptz not null default now());
create index if not exists materials_class on lab.materials(class_id, created_at);
alter table lab.materials enable row level security;

-- к чему прикреплён материал: 'class', 'work:<работа>' или 'test:<тест этого учителя>'
create or replace function lab.mat_target_ok(p_teacher uuid, p_target text) returns boolean language sql stable set search_path = '' as $$
  select p_target = 'class' or p_target ~ '^work:[a-z0-9]{2,20}$'
    or (p_target ~ '^test:[0-9a-f-]{36}$' and exists(select 1 from lab.tests t where t.id = substr(p_target, 6)::uuid and t.teacher_id = p_teacher)) $$;

create or replace function lab.mat_json(p_class uuid) returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'target', m.target, 'title', m.title, 'kind', m.kind, 'url', m.url, 'path', m.path,
      'size', m.size, 'mime', m.mime, 'at', m.created_at,
      'test', case when m.target like 'test:%' then (select t.title from lab.tests t where t.id::text = substr(m.target, 6)) end) order by m.created_at), '[]'::jsonb)
  from lab.materials m where m.class_id = p_class and m.status = 'ready' $$;

create or replace function public.t_mat_list(p_token text, p_class uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('mats', lab.mat_json(c.id),
    'used', (select coalesce(sum(size), 0) from lab.materials where teacher_id = c.teacher_id and status <> 'deleted'), 'quota', 209715200);
end $$;

create or replace function public.t_mat_link(p_token text, p_class uuid, p_target text, p_title text, p_url text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); nm text := lab.clean_name(p_title, 120); u text := btrim(coalesce(p_url, ''));
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if not lab.mat_target_ok(c.teacher_id, coalesce(p_target, '')) then return jsonb_build_object('err', 'target'); end if;
  if u !~* '^https?://[^\s<>"]+$' or length(u) > 1000 then return jsonb_build_object('err', 'url'); end if;
  if nm = '' then nm := left(regexp_replace(u, '^https?://', '', 'i'), 120); end if;
  if (select count(*) from lab.materials where class_id = c.id and status <> 'deleted') >= 100 then return jsonb_build_object('err', 'mlimit'); end if;
  insert into lab.materials(teacher_id, class_id, target, title, kind, url) values (c.teacher_id, c.id, p_target, nm, 'link', u);
  return jsonb_build_object('mats', lab.mat_json(c.id));
end $$;

create or replace function public.t_mat_file(p_token text, p_class uuid, p_target text, p_title text, p_name text, p_size bigint, p_mime text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); nm text := lab.clean_name(p_title, 120); id uuid := gen_random_uuid();
  fn text := lower(regexp_replace(coalesce(p_name, ''), '[^A-Za-z0-9._-]+', '_', 'g')); pth text;
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if not lab.mat_target_ok(c.teacher_id, coalesce(p_target, '')) then return jsonb_build_object('err', 'target'); end if;
  if coalesce(p_mime, '') not in ('application/pdf', 'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.oasis.opendocument.presentation', 'application/vnd.oasis.opendocument.text',
      'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'video/mp4', 'text/plain') then return jsonb_build_object('err', 'ftype'); end if;
  if coalesce(p_size, 0) <= 0 or p_size > 20971520 then return jsonb_build_object('err', 'fsize'); end if;
  if (select coalesce(sum(size), 0) from lab.materials where teacher_id = c.teacher_id and status <> 'deleted') + p_size > 209715200 then return jsonb_build_object('err', 'quota'); end if;
  if (select count(*) from lab.materials where class_id = c.id and status <> 'deleted') >= 100 then return jsonb_build_object('err', 'mlimit'); end if;
  if (select count(*) from lab.materials where teacher_id = c.teacher_id and created_at > now() - interval '1 hour') >= 60 then return jsonb_build_object('err', 'slow'); end if;
  fn := left(trim(both '_' from fn), 80); if fn = '' or fn !~ '\.' then fn := 'file'; elsif fn ~ '^\.' then fn := 'file' || fn; end if;
  if nm = '' then nm := lab.clean_name(p_name, 120); end if;
  pth := c.teacher_id::text || '/' || id::text || '/' || fn;
  insert into lab.materials(id, teacher_id, class_id, target, title, kind, path, size, mime, status) values (id, c.teacher_id, c.id, p_target, nm, 'file', pth, p_size, p_mime, 'pending');
  return jsonb_build_object('id', id, 'path', pth);
end $$;

create or replace function public.t_mat_done(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); m lab.materials; sz bigint;
begin
  select * into m from lab.materials where id = p_id and teacher_id = t.id;
  if t.id is null or m.id is null then return jsonb_build_object('err', 'session'); end if;
  if m.status = 'pending' then
    select (o.metadata->>'size')::bigint into sz from storage.objects o where o.bucket_id = 'materials' and o.name = m.path;
    if sz is null then return jsonb_build_object('err', 'upload'); end if;
    update lab.materials set status = 'ready', size = sz where id = m.id;
  end if;
  return jsonb_build_object('mats', lab.mat_json(m.class_id));
end $$;

create or replace function public.t_mat_delete(p_token text, p_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); m lab.materials;
begin
  select * into m from lab.materials where id = p_id and teacher_id = t.id;
  if t.id is null or m.id is null then return jsonb_build_object('err', 'session'); end if;
  update lab.materials set status = 'deleted' where id = m.id;
  return jsonb_build_object('path', m.path, 'mats', lab.mat_json(m.class_id));
end $$;

create or replace function public.s_materials(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('mats', '[]'::jsonb); end if;
  select * into st from lab.students where id = s.student_id;
  return jsonb_build_object('mats', lab.mat_json(st.class_id));
end $$;

-- проверки для политик хранилища (вызываются от имени anon)
create or replace function public.mat_upload_ok(p_name text) returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from lab.materials m where m.path = p_name and m.status = 'pending' and m.created_at > now() - interval '1 hour') $$;
create or replace function public.mat_remove_ok(p_name text) returns boolean language sql stable security definer set search_path = '' as $$
  select exists(select 1 from lab.materials m where m.path = p_name and m.status = 'deleted') $$;

revoke all on function lab.mat_target_ok(uuid, text) from public;
revoke all on function lab.mat_json(uuid) from public;
do $$ declare f text; begin
  foreach f in array array['t_mat_list(text, uuid)', 't_mat_link(text, uuid, text, text, text)', 't_mat_file(text, uuid, text, text, text, bigint, text)',
      't_mat_done(text, uuid)', 't_mat_delete(text, uuid)', 's_materials(text)', 'mat_upload_ok(text)', 'mat_remove_ok(text)'] loop
    execute format('revoke all on function public.%s from public', f);
    if exists(select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function public.%s to anon, authenticated', f); end if;
  end loop;
end $$;

-- хранилище: bucket и политики (только там, где есть Supabase Storage)
do $$ begin
  if exists(select 1 from pg_namespace where nspname = 'storage') then
    insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
    values ('materials', 'materials', true, 20971520, array['application/pdf', 'application/vnd.ms-powerpoint', 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'application/msword', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', 'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', 'application/vnd.oasis.opendocument.presentation', 'application/vnd.oasis.opendocument.text',
      'image/png', 'image/jpeg', 'image/gif', 'image/webp', 'video/mp4', 'text/plain'])
    on conflict (id) do update set public = true, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
    if not exists(select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname = 'materials upload') then
      create policy "materials upload" on storage.objects for insert to anon with check (bucket_id = 'materials' and public.mat_upload_ok(name));
      create policy "materials remove read" on storage.objects for select to anon using (bucket_id = 'materials' and public.mat_remove_ok(name));
      create policy "materials remove" on storage.objects for delete to anon using (bucket_id = 'materials' and public.mat_remove_ok(name));
    end if;
  end if;
end $$;
