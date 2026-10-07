-- Лаборатория Сириус: объявление классу и данные для итоговой ведомости.
-- Учитель пишет короткое объявление — ученики класса видят его на странице работ.
-- Выполнять после schema.sql, tests.sql и materials.sql.

alter table lab.classes add column if not exists notice text not null default '';
alter table lab.classes add column if not exists notice_at timestamptz;

-- объявление и баллы за тесты класса (для ведомости)
create or replace function public.t_class_extra(p_token text, p_class uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('notice', c.notice, 'notice_at', c.notice_at,
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('test', ct.test_id, 'title', q.title,
        'attempts', (select coalesce(jsonb_agg(jsonb_build_object('student', a.student_id, 'score', a.score, 'max', a.max,
            'done', a.finished_at is not null or a.ends_at < now())), '[]'::jsonb) from lab.attempts a where a.class_id = c.id and a.test_id = ct.test_id))
        order by q.title), '[]'::jsonb)
      from lab.class_tests ct join lab.tests q on q.id = ct.test_id where ct.class_id = c.id));
end $$;

create or replace function public.t_notice_set(p_token text, p_class uuid, p_text text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); x text := left(btrim(coalesce(p_text, '')), 1000);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  update lab.classes set notice = x, notice_at = case when x = '' then null else now() end where id = c.id;
  return jsonb_build_object('notice', x, 'notice_at', case when x = '' then null else now() end);
end $$;

-- ученик: материалы класса и объявление учителя
create or replace function public.s_materials(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); c lab.classes;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('mats', '[]'::jsonb); end if;
  select cl.* into c from lab.classes cl join lab.students st on st.class_id = cl.id where st.id = s.student_id;
  return jsonb_build_object('mats', lab.mat_json(c.id), 'notice', c.notice, 'notice_at', c.notice_at);
end $$;

revoke all on function public.t_class_extra(text, uuid) from public;
revoke all on function public.t_notice_set(text, uuid, text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.t_class_extra(text, uuid) to anon, authenticated;
    grant execute on function public.t_notice_set(text, uuid, text) to anon, authenticated;
  end if;
end $$;
