-- Лаборатория Сириус: наблюдение администратора за учителями — только просмотр.
-- Администратор видит классы учителя, учеников (без личных кодов), открытые работы, журнал и тесты.
-- Выполнять после schema.sql, tests.sql и applications.sql.

-- заявка, по которой зарегистрировался учитель (последняя одобренная с его почтой)
create or replace function lab.app_json(p_email text) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('name', a.name, 'school', a.school, 'classes', a.classes, 'comment', a.comment, 'at', a.created_at)
  from lab.applications a where a.email = p_email and a.status = 'approved' order by a.decided_at desc nulls last limit 1 $$;

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
        'students', (select count(*) from lab.students s join lab.classes c on c.id = s.class_id where c.teacher_id = x.id),
        'app', lab.app_json(x.email)) order by x.created_at), '[]'::jsonb)
      from lab.teachers x));
end $$;

create or replace function public.a_teacher_view(p_token text, p_teacher uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); x lab.teachers;
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  select * into x from lab.teachers where id = p_teacher;
  if x.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object(
    'teacher', jsonb_build_object('id', x.id, 'name', x.name, 'email', x.email, 'admin', x.is_admin, 'blocked', x.blocked, 'created', x.created_at),
    'app', lab.app_json(x.email),
    'tests', (select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'minutes', q.minutes, 'n', jsonb_array_length(q.qs)) order by q.updated_at desc), '[]'::jsonb)
      from lab.tests q where q.teacher_id = x.id),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
        'students', (select coalesce(jsonb_agg(jsonb_build_object('id', s.id, 'name', s.name, 'joined', s.joined_at, 'seen', s.seen_at) order by s.name, s.created_at), '[]'::jsonb)
          from lab.students s where s.class_id = c.id),
        'works', lab.works_json(c.id),
        'results', (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'student', r.student_id, 'work', r.work, 'ok', r.ok, 'data', r.data, 'at', r.created_at) order by r.id), '[]'::jsonb)
          from (select * from lab.results where class_id = c.id order by id desc limit 2000) r),
        'tests', (select coalesce(jsonb_agg(jsonb_build_object('test', ct.test_id, 'title', q.title, 'deadline', ct.deadline,
            'attempts', (select coalesce(jsonb_agg(jsonb_build_object('student', a.student_id, 'score', a.score, 'max', a.max, 'leaves', a.leaves,
                'done', a.finished_at is not null or a.ends_at < now()) order by a.started_at), '[]'::jsonb)
              from lab.attempts a where a.class_id = c.id and a.test_id = ct.test_id)) order by q.title), '[]'::jsonb)
          from lab.class_tests ct join lab.tests q on q.id = ct.test_id where ct.class_id = c.id)) order by c.name, c.created_at), '[]'::jsonb)
      from lab.classes c where c.teacher_id = x.id));
end $$;

revoke all on function lab.app_json(text) from public;
revoke all on function public.a_teacher_view(text, uuid) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.a_teacher_view(text, uuid) to anon, authenticated;
  end if;
end $$;
