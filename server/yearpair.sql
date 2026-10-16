-- Лаборатория Сириус: новый учебный год и работа в паре.
-- Новый учебный год: учитель создаёт следующий класс (например, 8Б из 7Б). Ученики переходят в него
-- с теми же личными кодами и устройствами и остаются в своём входе; старый класс уходит в архив
-- вместе с журналом, оценками и тестами — его можно открыть и вернуть из архива.
-- Работа в паре: ученик на своём устройстве вписывает код напарника из своего класса;
-- результат с оценкой сохраняется обоим, в журнале видно, кто с кем работал.
-- Выполнять после schema.sql, tests.sql и classinfo.sql.

alter table lab.classes add column if not exists archived boolean not null default false;
alter table lab.classes add column if not exists archived_at timestamptz;
alter table lab.classes add column if not exists next_class uuid;

create or replace function public.t_me(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('me', lab.me_json(t),
    'classes', (select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'archived', c.archived, 'archived_at', c.archived_at,
        'next', (select n.name from lab.classes n where n.id = c.next_class),
        'students', (select count(*) from lab.students s where s.class_id = c.id),
        'joined', (select count(*) from lab.students s where s.class_id = c.id and s.joined_at is not null)) order by c.archived, c.name, c.created_at), '[]'::jsonb)
      from lab.classes c where c.teacher_id = t.id),
    'demo', (select jsonb_build_object('code', d.code, 'expires', d.expires_at) from lab.demos d
      where d.teacher_id = t.id and d.expires_at > now() order by d.expires_at desc limit 1));
end $$;

-- новый учебный год: новый класс, ученики переходят с теми же кодами, старый класс — в архив
create or replace function public.t_new_year(p_token text, p_class uuid, p_name text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); nm text := lab.clean_name(p_name, 40); nid uuid; st lab.students; sid uuid; n int := 0;
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  if c.archived then return jsonb_build_object('err', 'archived'); end if;
  if length(nm) < 1 then return jsonb_build_object('err', 'name'); end if;
  if (select count(*) from lab.classes where teacher_id = c.teacher_id) >= 40 then return jsonb_build_object('err', 'limit'); end if;
  insert into lab.classes(teacher_id, name) values (c.teacher_id, nm) returning id into nid;
  for st in select * from lab.students where class_id = c.id order by created_at loop
    -- старой записи (с её результатами) даём код, по которому войти нельзя, а настоящий код переносим в новый класс
    update lab.students set code = 'old-' || st.id::text where id = st.id;
    insert into lab.students(class_id, name, code, device, joined_at, seen_at)
      values (nid, st.name, st.code, st.device, st.joined_at, st.seen_at) returning id into sid;
    update lab.sessions set student_id = sid where student_id = st.id;
    n := n + 1;
  end loop;
  update lab.classes set archived = true, archived_at = now(), next_class = nid where id = c.id;
  return jsonb_build_object('id', nid, 'moved', n);
end $$;

-- убрать класс в архив или вернуть из архива
create or replace function public.t_class_archive(p_token text, p_class uuid, p_on boolean) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  update lab.classes set archived = coalesce(p_on, true), archived_at = case when coalesce(p_on, true) then now() end where id = c.id;
  return jsonb_build_object('ok', true);
end $$;

-- напарник по коду: только ученик того же класса
create or replace function lab.partner(s lab.sessions, p_code text) returns lab.students language sql stable set search_path = '' as $$
  select p.* from lab.students p join lab.students me on me.id = s.student_id
  where s.kind = 's' and p.class_id = me.class_id and p.id <> me.id
    and p.code = upper(regexp_replace(coalesce(p_code, ''), '[\s-]', '', 'g')) $$;

create or replace function public.s_pair_check(p_token text, p_code text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); p lab.students;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('err', 'pair'); end if;
  if lab.too_many() then return jsonb_build_object('err', 'slow'); end if;
  p := lab.partner(s, p_code);
  if p.id is null then perform lab.fail(); return jsonb_build_object('err', 'pair'); end if;
  return jsonb_build_object('id', p.id, 'name', p.name);
end $$;

-- результат пары: сохраняется ученику и напарнику; у каждого в данных отмечено, с кем работал
create or replace function public.s_submit_pair(p_token text, p_work text, p_ok boolean, p_data jsonb, p_partner text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students; p lab.students; cw lab.class_works;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('ok', true, 'saved', false); end if;
  if lab.too_many() then return jsonb_build_object('err', 'slow'); end if;
  select * into st from lab.students where id = s.student_id;
  p := lab.partner(s, p_partner);
  if p.id is null then perform lab.fail(); return jsonb_build_object('err', 'pair'); end if;
  select * into cw from lab.class_works where class_id = st.class_id and work = p_work;
  if cw.work is null then return jsonb_build_object('err', 'closed'); end if;
  if cw.deadline is not null and cw.deadline < now() then return jsonb_build_object('err', 'late'); end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' or length(p_data::text) > 30000 then return jsonb_build_object('err', 'data'); end if;
  if (select count(*) from lab.results where student_id = st.id and created_at > now() - interval '1 hour') >= 60 then return jsonb_build_object('err', 'slow'); end if;
  insert into lab.results(student_id, class_id, work, ok, data)
    values (st.id, st.class_id, p_work, coalesce(p_ok, false), p_data || jsonb_build_object('pair', p.id, 'pn', p.name)),
           (p.id, st.class_id, p_work, coalesce(p_ok, false), p_data || jsonb_build_object('pair', st.id, 'pn', st.name));
  update lab.students set seen_at = now() where id = st.id;
  return jsonb_build_object('ok', true, 'saved', true, 'partner', p.name);
end $$;

revoke all on function lab.partner(lab.sessions, text) from public;
do $$ declare f text; begin
  foreach f in array array['t_me(text)', 't_new_year(text, uuid, text)', 't_class_archive(text, uuid, boolean)',
      's_pair_check(text, text)', 's_submit_pair(text, text, boolean, jsonb, text)'] loop
    execute format('revoke all on function public.%s from public', f);
    if exists(select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function public.%s to anon, authenticated', f); end if;
  end loop;
end $$;
