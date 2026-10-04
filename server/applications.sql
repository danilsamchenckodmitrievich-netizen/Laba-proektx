-- Лаборатория Сириус: заявки на регистрацию учителя.
-- Учитель оставляет заявку на сайте, администратор одобряет её в кабинете: сервер создаёт
-- приглашение, а сайт готовит письмо с кодом. IP не хранится — только его хэш для защиты от спама.

create table if not exists lab.applications(
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  name text not null,
  email text not null,
  school text not null,
  classes text not null default '',
  comment text not null default '',
  status text not null default 'new' check (status in ('new','approved','rejected')),
  invite_code text,
  reason text not null default '',
  decided_at timestamptz,
  ip_hash text not null default '');
create index if not exists applications_created on lab.applications(created_at desc);
alter table lab.applications enable row level security;

create or replace function public.apply_teacher(p_name text, p_email text, p_school text, p_classes text, p_comment text, p_hp text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare nm text := lab.clean_name(p_name, 80); e text := lower(btrim(coalesce(p_email, ''))); sc text := lab.clean_name(p_school, 120);
  iph text := lab.h('ip:' || lab.ip());
begin
  if coalesce(p_hp, '') <> '' then return jsonb_build_object('ok', true); end if;
  if length(nm) < 2 then return jsonb_build_object('err', 'name'); end if;
  if e !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or length(e) > 120 then return jsonb_build_object('err', 'email'); end if;
  if length(sc) < 2 then return jsonb_build_object('err', 'school'); end if;
  if (select count(*) from lab.applications where ip_hash = iph and created_at > now() - interval '1 day') >= 3
    or (select count(*) from lab.applications where created_at > now() - interval '1 hour') >= 50 then return jsonb_build_object('err', 'slow'); end if;
  if exists(select 1 from lab.teachers where email = e) then return jsonb_build_object('err', 'taken'); end if;
  if exists(select 1 from lab.applications where email = e and status = 'new') then return jsonb_build_object('ok', true, 'again', true); end if;
  insert into lab.applications(name, email, school, classes, comment, ip_hash)
    values (nm, e, sc, lab.clean_name(p_classes, 60), left(btrim(coalesce(p_comment, '')), 500), iph);
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.a_apps(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('new', (select count(*) from lab.applications where status = 'new'),
    'apps', (select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'at', a.created_at, 'name', a.name, 'email', a.email, 'school', a.school,
        'classes', a.classes, 'comment', a.comment, 'status', a.status, 'code', a.invite_code, 'reason', a.reason, 'decided', a.decided_at,
        'used', (select i.used_at is not null from lab.invites i where i.code = a.invite_code))
      order by (a.status = 'new') desc, a.created_at desc), '[]'::jsonb)
      from (select * from lab.applications order by created_at desc limit 200) a));
end $$;

create or replace function public.a_app_decide(p_token text, p_app uuid, p_approve boolean, p_reason text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); a lab.applications; k text;
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  select * into a from lab.applications where id = p_app for update;
  if a.id is null then return jsonb_build_object('err', 'session'); end if;
  if a.status <> 'new' then return jsonb_build_object('err', 'decided'); end if;
  if p_approve then
    loop k := lab.rand_code(4) || '-' || lab.rand_code(4); exit when not exists(select 1 from lab.invites where code = k); end loop;
    insert into lab.invites(code, note, is_admin, created_by, expires_at)
      values (k, lab.clean_name(a.name || ' · ' || a.school, 80), false, t.id, now() + interval '30 days');
    update lab.applications set status = 'approved', invite_code = k, decided_at = now() where id = a.id;
    return jsonb_build_object('code', k, 'name', a.name, 'email', a.email);
  end if;
  update lab.applications set status = 'rejected', reason = left(btrim(coalesce(p_reason, '')), 300), decided_at = now() where id = a.id;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.apply_teacher(text, text, text, text, text, text) from public;
revoke all on function public.a_apps(text) from public;
revoke all on function public.a_app_decide(text, uuid, boolean, text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.apply_teacher(text, text, text, text, text, text) to anon, authenticated;
    grant execute on function public.a_apps(text) to anon, authenticated;
    grant execute on function public.a_app_decide(text, uuid, boolean, text) to anon, authenticated;
  end if;
end $$;
