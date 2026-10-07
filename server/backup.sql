-- Лаборатория Сириус: резервная копия данных для администратора (кнопка в кабинете).
-- В копию не входят хэши паролей, сессии и отметки устройств учеников; IP-хэши заявок тоже не выгружаются.
-- Выполнять после всех остальных файлов.

create or replace function public.a_backup(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('format', 'lab-sirius-backup-1', 'created', now(), 'by', t.email,
    'teachers', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'email', x.email, 'name', x.name, 'is_admin', x.is_admin, 'blocked', x.blocked, 'created_at', x.created_at) order by x.created_at), '[]') from lab.teachers x),
    'invites', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]') from lab.invites x),
    'applications', (select coalesce(jsonb_agg(to_jsonb(x) - 'ip_hash' order by x.created_at), '[]') from lab.applications x),
    'classes', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]') from lab.classes x),
    'students', (select coalesce(jsonb_agg(to_jsonb(x) - 'device' order by x.created_at), '[]') from lab.students x),
    'class_works', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from lab.class_works x),
    'results', (select coalesce(jsonb_agg(to_jsonb(x) order by x.id), '[]') from lab.results x),
    'tests', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]') from lab.tests x),
    'class_tests', (select coalesce(jsonb_agg(to_jsonb(x)), '[]') from lab.class_tests x),
    'attempts', (select coalesce(jsonb_agg(to_jsonb(x) order by x.started_at), '[]') from lab.attempts x),
    'materials', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at), '[]') from lab.materials x where x.status <> 'deleted'),
    'visits_by_day', (select coalesce(jsonb_agg(jsonb_build_object('day', v.day, 'visitors', v.n, 'views', v.views) order by v.day), '[]')
      from (select day, count(*) n, sum(views) views from lab.visits group by day) v),
    'page_hits', (select coalesce(jsonb_agg(to_jsonb(x) order by x.day), '[]') from lab.page_hits x));
end $$;

revoke all on function public.a_backup(text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then grant execute on function public.a_backup(text) to anon, authenticated; end if;
end $$;
