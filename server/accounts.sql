-- Лаборатория Сириус: удаление аккаунта учителя.
-- Удаляются учитель, его классы, ученики, результаты, тесты и попытки (через on delete cascade),
-- а также заявки с его почтой. Выполнять после schema.sql, tests.sql и applications.sql.

create or replace function lab.del_teacher(p_id uuid) returns void language sql set search_path = '' as $$
  delete from lab.applications a where a.email = (select t.email from lab.teachers t where t.id = p_id);
  delete from lab.teachers t where t.id = p_id $$;

-- администратор удаляет другого учителя
create or replace function public.a_teacher_delete(p_token text, p_teacher uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  if p_teacher = t.id then return jsonb_build_object('err', 'selfdel'); end if;
  if not exists(select 1 from lab.teachers where id = p_teacher) then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_teacher(p_teacher);
  return jsonb_build_object('ok', true);
end $$;

-- учитель удаляет свой аккаунт, подтверждая паролем
create or replace function public.t_delete_me(p_token text, p_pass text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  if t.pass <> extensions.crypt(coalesce(p_pass, ''), t.pass) then perform lab.fail(); return jsonb_build_object('err', 'login'); end if;
  if t.is_admin and not exists(select 1 from lab.teachers where is_admin and not blocked and id <> t.id) then
    return jsonb_build_object('err', 'lastadmin'); end if;
  perform lab.del_teacher(t.id);
  return jsonb_build_object('ok', true);
end $$;

revoke all on function lab.del_teacher(uuid) from public;
revoke all on function public.a_teacher_delete(text, uuid) from public;
revoke all on function public.t_delete_me(text, text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.a_teacher_delete(text, uuid) to anon, authenticated;
    grant execute on function public.t_delete_me(text, text) to anon, authenticated;
  end if;
end $$;
