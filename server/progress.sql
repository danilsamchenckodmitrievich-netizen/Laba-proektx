-- Лаборатория Сириус: личный прогресс ученика — все свои попытки по работам с оценками.
-- Выполнять после schema.sql.

create or replace function public.s_progress(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token);
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('res', '[]'::jsonb); end if;
  return jsonb_build_object('res', (select coalesce(jsonb_agg(jsonb_build_object('work', r.work, 'g', r.data->'g', 'e', r.data->'e', 'q', r.data->'q', 't', r.data->'t', 'at', r.created_at) order by r.id), '[]'::jsonb)
    from lab.results r where r.student_id = s.student_id and r.ok));
end $$;

revoke all on function public.s_progress(text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then grant execute on function public.s_progress(text) to anon, authenticated; end if;
end $$;
