-- Лаборатория Сириус: сервер для классов, учеников и результатов.
-- Обычный Postgres 15+ с расширением pgcrypto. Таблицы лежат в схеме lab и снаружи не видны;
-- сайт вызывает только функции из схемы public (через REST: POST /rest/v1/rpc/<функция>).
-- Вход учителя и учеников устроен здесь же (своя таблица сессий), поэтому сервер можно перенести
-- на любой хостинг с Postgres и PostgREST без изменений в сайте, кроме адреса.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;
create schema if not exists lab;
revoke all on schema lab from public;

-- ===== таблицы
create table if not exists lab.teachers(
  id uuid primary key default gen_random_uuid(),
  email text not null unique,
  name text not null,
  pass text not null,
  is_admin boolean not null default false,
  blocked boolean not null default false,
  fails int not null default 0,
  locked_until timestamptz,
  created_at timestamptz not null default now());

create table if not exists lab.invites(
  code text primary key,
  note text not null default '',
  is_admin boolean not null default false,
  created_by uuid references lab.teachers(id) on delete set null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  used_by uuid references lab.teachers(id) on delete set null,
  used_at timestamptz);

create table if not exists lab.classes(
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references lab.teachers(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now());
create index if not exists classes_teacher on lab.classes(teacher_id);

create table if not exists lab.students(
  id uuid primary key default gen_random_uuid(),
  class_id uuid not null references lab.classes(id) on delete cascade,
  name text not null,
  code text not null unique,
  device text,
  joined_at timestamptz,
  seen_at timestamptz,
  created_at timestamptz not null default now());
create index if not exists students_class on lab.students(class_id);

-- строка есть — работа открыта классу; deadline — срок сдачи (null — без срока)
create table if not exists lab.class_works(
  class_id uuid not null references lab.classes(id) on delete cascade,
  work text not null,
  deadline timestamptz,
  opened_at timestamptz not null default now(),
  primary key(class_id, work));

create table if not exists lab.demos(
  code text primary key,
  teacher_id uuid not null references lab.teachers(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null);

-- в базе хранится только хэш токена
create table if not exists lab.sessions(
  token text primary key,
  kind text not null check (kind in ('t','s','d')),
  teacher_id uuid references lab.teachers(id) on delete cascade,
  student_id uuid references lab.students(id) on delete cascade,
  demo text references lab.demos(code) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null);

create table if not exists lab.results(
  id bigint generated always as identity primary key,
  student_id uuid not null references lab.students(id) on delete cascade,
  class_id uuid not null references lab.classes(id) on delete cascade,
  work text not null,
  ok boolean not null,
  data jsonb not null,
  created_at timestamptz not null default now());
create index if not exists results_class on lab.results(class_id, id);

create table if not exists lab.login_fails(ip text not null, at timestamptz not null default now());
create index if not exists login_fails_ip on lab.login_fails(ip, at);

alter table lab.teachers enable row level security;
alter table lab.invites enable row level security;
alter table lab.classes enable row level security;
alter table lab.students enable row level security;
alter table lab.class_works enable row level security;
alter table lab.demos enable row level security;
alter table lab.sessions enable row level security;
alter table lab.results enable row level security;
alter table lab.login_fails enable row level security;

-- ===== служебные функции (снаружи недоступны)
create or replace function lab.rand_code(n int) returns text language plpgsql volatile set search_path = '' as $$
declare a text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; b bytea := extensions.gen_random_bytes(n); r text := ''; i int;
begin for i in 0..n-1 loop r := r || substr(a, get_byte(b, i) % 32 + 1, 1); end loop; return r; end $$;

create or replace function lab.h(t text) returns text language sql immutable set search_path = '' as $$
  select encode(extensions.digest(coalesce(t,''), 'sha256'), 'hex') $$;

create or replace function lab.ip() returns text language plpgsql stable set search_path = '' as $$
declare h text := current_setting('request.headers', true);
begin
  if h is null or h = '' then return 'local'; end if;
  return coalesce(nullif(split_part(coalesce(h::json->>'cf-connecting-ip', h::json->>'x-forwarded-for', ''), ',', 1), ''), 'local');
exception when others then return 'local'; end $$;

-- слишком много неудачных попыток входа с одного адреса за 10 минут
create or replace function lab.too_many() returns boolean language sql stable set search_path = '' as $$
  select count(*) >= 30 from lab.login_fails where ip = lab.ip() and at > now() - interval '10 minutes' $$;

create or replace function lab.fail() returns void language sql set search_path = '' as $$
  delete from lab.login_fails where at < now() - interval '1 day';
  insert into lab.login_fails(ip) values (lab.ip()); $$;

create or replace function lab.new_session(k text, t uuid, s uuid, d text, ttl interval) returns text language plpgsql set search_path = '' as $$
declare tok text := encode(extensions.gen_random_bytes(24), 'hex');
begin
  delete from lab.sessions where expires_at < now();
  insert into lab.sessions(token, kind, teacher_id, student_id, demo, expires_at) values (lab.h(tok), k, t, s, d, now() + ttl);
  return tok;
end $$;

create or replace function lab.sess(p_token text) returns lab.sessions language sql stable set search_path = '' as $$
  select * from lab.sessions where token = lab.h(p_token) and expires_at > now() $$;

-- учитель по токену (null — нет входа или учитель заблокирован)
create or replace function lab.teacher(p_token text) returns lab.teachers language sql stable set search_path = '' as $$
  select t.* from lab.sessions s join lab.teachers t on t.id = s.teacher_id
  where s.token = lab.h(p_token) and s.kind = 't' and s.expires_at > now() and not t.blocked $$;

create or replace function lab.my_class(p_token text, p_class uuid) returns lab.classes language sql stable set search_path = '' as $$
  select c.* from lab.classes c where c.id = p_class and c.teacher_id = (lab.teacher(p_token)).id $$;

create or replace function lab.me_json(t lab.teachers) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('id', t.id, 'email', t.email, 'name', t.name, 'admin', t.is_admin) $$;

create or replace function lab.works_json(p_class uuid) returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('work', work, 'deadline', deadline) order by work), '[]'::jsonb)
  from lab.class_works where class_id = p_class $$;

create or replace function lab.clean_name(v text, n int) returns text language sql immutable set search_path = '' as $$
  select left(regexp_replace(btrim(coalesce(v, '')), '\s+', ' ', 'g'), n) $$;

-- удаления вынесены в отдельные функции
create or replace function lab.drop_sessions(p_teacher uuid, p_student uuid, p_keep text) returns void language sql set search_path = '' as $$
  delete from lab.sessions s
  where ((p_teacher is not null and s.teacher_id = p_teacher) or (p_student is not null and s.student_id = p_student))
    and s.token is distinct from p_keep $$;
create or replace function lab.del_class(p_id uuid) returns void language sql set search_path = '' as $$
  delete from lab.classes c where c.id = p_id $$;
create or replace function lab.del_student(p_id uuid) returns void language sql set search_path = '' as $$
  delete from lab.students s where s.id = p_id $$;
create or replace function lab.del_work(p_class uuid, p_work text) returns void language sql set search_path = '' as $$
  delete from lab.class_works w where w.class_id = p_class and w.work = p_work $$;
create or replace function lab.del_demos(p_teacher uuid) returns void language sql set search_path = '' as $$
  delete from lab.demos d where d.teacher_id = p_teacher $$;
create or replace function lab.del_invite(p_code text) returns void language sql set search_path = '' as $$
  delete from lab.invites i where i.code = p_code and i.used_at is null $$;

-- ===== API: общее
create or replace function public.ping() returns jsonb language sql stable set search_path = '' as $$ select jsonb_build_object('ok', true, 'now', now()) $$;

create or replace function public.logout(p_token text) returns jsonb language sql security definer set search_path = '' as $$
  delete from lab.sessions where token = lab.h(p_token);
  select jsonb_build_object('ok', true) $$;

-- ===== API: учитель
create or replace function public.t_register(p_invite text, p_email text, p_name text, p_pass text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare inv lab.invites; t lab.teachers; e text := lower(btrim(coalesce(p_email, ''))); nm text := lab.clean_name(p_name, 80);
begin
  if lab.too_many() then return jsonb_build_object('err', 'slow'); end if;
  select * into inv from lab.invites where code = upper(btrim(coalesce(p_invite, ''))) for update;
  if inv.code is null or inv.used_at is not null or inv.expires_at < now() then perform lab.fail(); return jsonb_build_object('err', 'invite'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 120 then return jsonb_build_object('err', 'email'); end if;
  if length(nm) < 2 then return jsonb_build_object('err', 'name'); end if;
  if length(coalesce(p_pass, '')) < 8 or length(p_pass) > 72 then return jsonb_build_object('err', 'pass'); end if;
  if exists(select 1 from lab.teachers where email = e) then return jsonb_build_object('err', 'taken'); end if;
  insert into lab.teachers(email, name, pass, is_admin) values (e, nm, extensions.crypt(p_pass, extensions.gen_salt('bf', 10)), inv.is_admin) returning * into t;
  update lab.invites set used_by = t.id, used_at = now() where code = inv.code;
  return jsonb_build_object('token', lab.new_session('t', t.id, null, null, interval '30 days'), 'me', lab.me_json(t));
end $$;

create or replace function public.t_login(p_email text, p_pass text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers; e text := lower(btrim(coalesce(p_email, '')));
begin
  if lab.too_many() then return jsonb_build_object('err', 'slow'); end if;
  select * into t from lab.teachers where email = e for update;
  if t.id is null then perform lab.fail(); return jsonb_build_object('err', 'login'); end if;
  if t.locked_until is not null and t.locked_until > now() then return jsonb_build_object('err', 'slow'); end if;
  if t.pass <> extensions.crypt(coalesce(p_pass, ''), t.pass) then
    perform lab.fail();
    -- после 8 неверных паролей подряд вход в этот аккаунт закрывается на 15 минут
    update lab.teachers set fails = case when fails + 1 >= 8 then 0 else fails + 1 end,
      locked_until = case when fails + 1 >= 8 then now() + interval '15 minutes' else locked_until end where id = t.id;
    return jsonb_build_object('err', 'login');
  end if;
  if t.blocked then return jsonb_build_object('err', 'blocked'); end if;
  update lab.teachers set fails = 0, locked_until = null where id = t.id;
  return jsonb_build_object('token', lab.new_session('t', t.id, null, null, interval '30 days'), 'me', lab.me_json(t));
end $$;

create or replace function public.t_me(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('me', lab.me_json(t),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
        'students', (select count(*) from lab.students s where s.class_id = c.id),
        'joined', (select count(*) from lab.students s where s.class_id = c.id and s.joined_at is not null)) order by c.name, c.created_at), '[]'::jsonb)
      from lab.classes c where c.teacher_id = t.id),
    'demo', (select jsonb_build_object('code', d.code, 'expires', d.expires_at) from lab.demos d
      where d.teacher_id = t.id and d.expires_at > now() order by d.expires_at desc limit 1));
end $$;

create or replace function public.t_password(p_token text, p_old text, p_new text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  if t.pass <> extensions.crypt(coalesce(p_old, ''), t.pass) then perform lab.fail(); return jsonb_build_object('err', 'login'); end if;
  if length(coalesce(p_new, '')) < 8 or length(p_new) > 72 then return jsonb_build_object('err', 'pass'); end if;
  update lab.teachers set pass = extensions.crypt(p_new, extensions.gen_salt('bf', 10)) where id = t.id;
  perform lab.drop_sessions(t.id, null, lab.h(p_token));
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.t_class_create(p_token text, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); nm text := lab.clean_name(p_name, 40); cid uuid;
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  if length(nm) < 1 then return jsonb_build_object('err', 'name'); end if;
  if (select count(*) from lab.classes where teacher_id = t.id) >= 40 then return jsonb_build_object('err', 'limit'); end if;
  insert into lab.classes(teacher_id, name) values (t.id, nm) returning id into cid;
  return jsonb_build_object('id', cid);
end $$;

create or replace function public.t_class_rename(p_token text, p_class uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); nm text := lab.clean_name(p_name, 40);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if length(nm) < 1 then return jsonb_build_object('err', 'name'); end if;
  update lab.classes set name = nm where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.t_class_delete(p_token text, p_class uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_class(c.id);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.t_class(p_token text, p_class uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('class', jsonb_build_object('id', c.id, 'name', c.name),
    'students', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'code', s.code, 'joined', s.joined_at, 'seen', s.seen_at)
      order by s.name, s.created_at), '[]'::jsonb) from lab.students s where s.class_id = c.id),
    'works', lab.works_json(c.id));
end $$;

create or replace function public.t_students_add(p_token text, p_class uuid, p_names text[]) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); nm text; n int := 0; k text;
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if (select count(*) from lab.students where class_id = c.id) + coalesce(array_length(p_names, 1), 0) > 60 then return jsonb_build_object('err', 'limit'); end if;
  foreach nm in array coalesce(p_names, '{}'::text[]) loop
    nm := lab.clean_name(nm, 40);
    continue when length(nm) < 1;
    loop k := lab.rand_code(6); exit when not exists(select 1 from lab.students where code = k) and not exists(select 1 from lab.demos where code = k); end loop;
    insert into lab.students(class_id, name, code) values (c.id, nm, k); n := n + 1;
  end loop;
  return jsonb_build_object('added', n);
end $$;

create or replace function public.t_student_rename(p_token text, p_student uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare nm text := lab.clean_name(p_name, 40);
begin
  if length(nm) < 1 then return jsonb_build_object('err', 'name'); end if;
  update lab.students s set name = nm from lab.classes c where s.id = p_student and c.id = s.class_id and c.teacher_id = (lab.teacher(p_token)).id;
  if not found then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.t_student_delete(p_token text, p_student uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not exists(select 1 from lab.students s join lab.classes c on c.id = s.class_id where s.id = p_student and c.teacher_id = (lab.teacher(p_token)).id)
    then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_student(p_student);
  return jsonb_build_object('ok', true);
end $$;

-- ученик сменил телефон или очистил браузер: разрешить вход с нового устройства
create or replace function public.t_student_reset(p_token text, p_student uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  update lab.students s set device = null, joined_at = null from lab.classes c
    where s.id = p_student and c.id = s.class_id and c.teacher_id = (lab.teacher(p_token)).id;
  if not found then return jsonb_build_object('err', 'session'); end if;
  perform lab.drop_sessions(null, p_student, null);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.t_work_set(p_token text, p_class uuid, p_work text, p_open boolean, p_deadline timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if p_work not in ('mass','volume','density','spring','frictionw','buoy','leverw','eff','small','floatw') then return jsonb_build_object('err', 'work'); end if;
  if p_open then
    insert into lab.class_works(class_id, work, deadline) values (c.id, p_work, p_deadline)
      on conflict (class_id, work) do update set deadline = excluded.deadline;
  else
    perform lab.del_work(c.id, p_work);
  end if;
  return jsonb_build_object('works', lab.works_json(c.id));
end $$;

-- журнал: результаты новее p_since и список учеников (кто уже вошёл)
create or replace function public.t_journal(p_token text, p_class uuid, p_since bigint) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object(
    'results', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'student', r.student_id, 'work', r.work, 'ok', r.ok, 'data', r.data, 'at', r.created_at) order by r.id), '[]'::jsonb)
      from (select * from lab.results where class_id = c.id and id > coalesce(p_since, 0) order by id limit 3000) r),
    'students', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'joined', s.joined_at, 'seen', s.seen_at) order by s.name, s.created_at), '[]'::jsonb)
      from lab.students s where s.class_id = c.id),
    'works', lab.works_json(c.id), 'now', now());
end $$;

-- демо-код: только из аккаунта учителя, действует ограниченное время, результаты не сохраняются
create or replace function public.t_demo(p_token text, p_minutes int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); k text; m int := least(greatest(coalesce(p_minutes, 45), 10), 120); ex timestamptz;
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_demos(t.id);
  loop k := lab.rand_code(6); exit when not exists(select 1 from lab.students where code = k) and not exists(select 1 from lab.demos where code = k); end loop;
  ex := now() + make_interval(mins => m);
  insert into lab.demos(code, teacher_id, expires_at) values (k, t.id, ex);
  return jsonb_build_object('code', k, 'expires', ex);
end $$;

create or replace function public.t_demo_stop(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_demos(t.id);
  return jsonb_build_object('ok', true);
end $$;

-- ===== API: администраторы (авторы проекта)
create or replace function public.a_overview(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object(
    'invites', (select coalesce(jsonb_agg(jsonb_build_object('code', i.code, 'note', i.note, 'admin', i.is_admin, 'created', i.created_at, 'expires', i.expires_at,
        'used', i.used_at, 'by', (select x.name || ' · ' || x.email from lab.teachers x where x.id = i.used_by)) order by i.created_at desc), '[]'::jsonb)
      from (select * from lab.invites order by created_at desc limit 200) i),
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'name', x.name, 'email', x.email, 'admin', x.is_admin, 'blocked', x.blocked, 'created', x.created_at,
        'classes', (select count(*) from lab.classes c where c.teacher_id = x.id),
        'students', (select count(*) from lab.students s join lab.classes c on c.id = s.class_id where c.teacher_id = x.id)) order by x.created_at), '[]'::jsonb)
      from lab.teachers x));
end $$;

create or replace function public.a_invite(p_token text, p_note text, p_days int, p_admin boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); k text;
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  loop k := lab.rand_code(4) || '-' || lab.rand_code(4); exit when not exists(select 1 from lab.invites where code = k); end loop;
  insert into lab.invites(code, note, is_admin, created_by, expires_at)
    values (k, lab.clean_name(p_note, 80), coalesce(p_admin, false), t.id, now() + make_interval(days => least(greatest(coalesce(p_days, 14), 1), 90)));
  return jsonb_build_object('code', k);
end $$;

create or replace function public.a_invite_delete(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_invite(p_code);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.a_teacher_block(p_token text, p_teacher uuid, p_blocked boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  if p_teacher = t.id then return jsonb_build_object('err', 'self'); end if;
  update lab.teachers set blocked = coalesce(p_blocked, true) where id = p_teacher;
  if p_blocked then perform lab.drop_sessions(p_teacher, null, null); perform lab.del_demos(p_teacher); end if;
  return jsonb_build_object('ok', true);
end $$;

-- временный пароль для учителя, который забыл свой
create or replace function public.a_teacher_reset(p_token text, p_teacher uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); pw text := lower(lab.rand_code(10));
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  update lab.teachers set pass = extensions.crypt(pw, extensions.gen_salt('bf', 10)), fails = 0, locked_until = null where id = p_teacher;
  if not found then return jsonb_build_object('err', 'session'); end if;
  perform lab.drop_sessions(p_teacher, null, null);
  return jsonb_build_object('pass', pw);
end $$;

-- ===== API: ученик и демо-режим
create or replace function lab.student_state(st lab.students) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('kind', 's', 'name', st.name, 'cls', c.name, 'works', lab.works_json(c.id),
    'done', (select coalesce(jsonb_agg(distinct r.work), '[]'::jsonb) from lab.results r where r.student_id = st.id and r.ok), 'now', now())
  from lab.classes c where c.id = st.class_id $$;

create or replace function public.s_login(p_code text, p_device text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare k text := upper(regexp_replace(coalesce(p_code, ''), '[\s-]', '', 'g')); st lab.students; d lab.demos; tn text;
begin
  if lab.too_many() then return jsonb_build_object('err', 'slow'); end if;
  if length(coalesce(p_device, '')) < 8 then return jsonb_build_object('err', 'device'); end if;
  select * into st from lab.students where code = k for update;
  if st.id is not null then
    if st.device is not null and st.device <> p_device then return jsonb_build_object('err', 'device'); end if;
    update lab.students set device = p_device, joined_at = coalesce(joined_at, now()), seen_at = now() where id = st.id returning * into st;
    return lab.student_state(st) || jsonb_build_object('token', lab.new_session('s', null, st.id, null, interval '150 days'));
  end if;
  select * into d from lab.demos where code = k and expires_at > now();
  if d.code is not null then
    select name into tn from lab.teachers where id = d.teacher_id;
    return jsonb_build_object('kind', 'd', 'expires', d.expires_at, 'teacher', tn, 'now', now(),
      'token', lab.new_session('d', null, null, d.code, d.expires_at - now()));
  end if;
  perform lab.fail();
  return jsonb_build_object('err', 'code');
end $$;

create or replace function public.s_state(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind = 's' then
    update lab.students set seen_at = now() where id = s.student_id returning * into st;
    return lab.student_state(st);
  elsif s.kind = 'd' then
    return jsonb_build_object('kind', 'd', 'expires', s.expires_at, 'now', now());
  end if;
  return jsonb_build_object('kind', 't', 'now', now());
end $$;

create or replace function public.s_submit(p_token text, p_work text, p_ok boolean, p_data jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students; cw lab.class_works;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('ok', true, 'saved', false); end if;
  select * into st from lab.students where id = s.student_id;
  select * into cw from lab.class_works where class_id = st.class_id and work = p_work;
  if cw.work is null then return jsonb_build_object('err', 'closed'); end if;
  if cw.deadline is not null and cw.deadline < now() then return jsonb_build_object('err', 'late'); end if;
  if p_data is null or length(p_data::text) > 30000 then return jsonb_build_object('err', 'data'); end if;
  if (select count(*) from lab.results where student_id = st.id and created_at > now() - interval '1 hour') >= 60 then return jsonb_build_object('err', 'slow'); end if;
  insert into lab.results(student_id, class_id, work, ok, data) values (st.id, st.class_id, p_work, coalesce(p_ok, false), p_data);
  update lab.students set seen_at = now() where id = st.id;
  return jsonb_build_object('ok', true, 'saved', true);
end $$;

-- ===== доступ: снаружи только функции API
revoke all on all functions in schema lab from public;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('ping','logout','t_register','t_login','t_me','t_password','t_class_create','t_class_rename','t_class_delete',
      't_class','t_students_add','t_student_rename','t_student_delete','t_student_reset','t_work_set','t_journal','t_demo','t_demo_stop',
      'a_overview','a_invite','a_invite_delete','a_teacher_block','a_teacher_reset','s_login','s_state','s_submit')
  loop
    execute format('revoke all on function %s from public', f.sig);
    if exists(select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f.sig); end if;
  end loop;
end $$;
