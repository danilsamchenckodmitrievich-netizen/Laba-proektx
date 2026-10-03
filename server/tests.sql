-- Лаборатория Сириус: тесты учителя (конструктор, выдача классу, попытки, проверка на сервере).
-- Правильные ответы никогда не уходят ученику: вопросы выбираются и перемешиваются на сервере,
-- ответы проверяются здесь же, время попытки считает сервер.

create table if not exists lab.tests(
  id uuid primary key default gen_random_uuid(),
  teacher_id uuid not null references lab.teachers(id) on delete cascade,
  title text not null,
  minutes int not null default 15,
  pick int,
  qs jsonb not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now());
create index if not exists tests_teacher on lab.tests(teacher_id);

create table if not exists lab.class_tests(
  class_id uuid not null references lab.classes(id) on delete cascade,
  test_id uuid not null references lab.tests(id) on delete cascade,
  deadline timestamptz,
  opened_at timestamptz not null default now(),
  primary key(class_id, test_id));

create table if not exists lab.attempts(
  id uuid primary key default gen_random_uuid(),
  test_id uuid not null references lab.tests(id) on delete cascade,
  class_id uuid not null references lab.classes(id) on delete cascade,
  student_id uuid not null references lab.students(id) on delete cascade,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  finished_at timestamptz,
  plan jsonb not null,
  answers jsonb not null default '{}',
  leaves int not null default 0,
  score numeric,
  max int,
  unique(test_id, student_id));
create index if not exists attempts_class on lab.attempts(class_id, test_id);

alter table lab.tests enable row level security;
alter table lab.class_tests enable row level security;
alter table lab.attempts enable row level security;

create or replace function lab.del_test(p_id uuid) returns void language sql set search_path = '' as $$
  delete from lab.tests t where t.id = p_id $$;
create or replace function lab.del_class_test(p_class uuid, p_test uuid) returns void language sql set search_path = '' as $$
  delete from lab.class_tests x where x.class_id = p_class and x.test_id = p_test $$;

-- нормализация текстового ответа: регистр, пробелы, ё → е, запятая → точка
create or replace function lab.norm(v text) returns text language sql immutable set search_path = '' as $$
  select replace(replace(regexp_replace(lower(btrim(coalesce(v, ''))), '\s+', ' ', 'g'), 'ё', 'е'), ',', '.') $$;

-- число из ответа ученика (запятая или точка); null — не число
create or replace function lab.num(v text) returns float8 language plpgsql immutable set search_path = '' as $$
begin
  if v is null or btrim(v) = '' then return null; end if;
  return replace(regexp_replace(btrim(v), '\s', '', 'g'), ',', '.')::float8;
exception when others then return null; end $$;

-- формула учителя с подставленными числами: только цифры, точки, скобки и знаки + - * / ^
create or replace function lab.calc(f text, vals jsonb) returns float8 language plpgsql stable set search_path = '' as $$
declare e text := lower(coalesce(f, '')); k text; r float8;
begin
  if length(e) > 300 or e !~ '^[0-9a-z_+\-*/^(). ]+$' then return null; end if;
  for k in select key from jsonb_each(coalesce(vals, '{}'::jsonb)) order by length(key) desc loop
    e := regexp_replace(e, '\m' || k || '\M', '(' || (vals->>k) || ')', 'g');
  end loop;
  if e !~ '^[0-9+\-*/^(). ]+$' then return null; end if;
  execute 'select (' || e || ')::float8' into r;
  return r;
exception when others then return null; end $$;

-- проверка вопросов теста; возвращает текст ошибки или null
create or replace function lab.check_qs(qs jsonb) returns text language plpgsql stable set search_path = '' as $$
declare q jsonb; i int := 0; k text; n int; v jsonb; vals jsonb;
begin
  if jsonb_typeof(qs) <> 'array' or jsonb_array_length(qs) < 1 or jsonb_array_length(qs) > 100 then return 'count'; end if;
  for q in select value from jsonb_array_elements(qs) loop
    i := i + 1; k := q->>'k';
    if length(btrim(coalesce(q->>'t', ''))) < 2 or length(q->>'t') > 2000 then return 'text:' || i; end if;
    if k in ('one', 'many') then
      if jsonb_typeof(q->'o') <> 'array' then return 'opts:' || i; end if;
      n := jsonb_array_length(q->'o');
      if n < 2 or n > 8 then return 'opts:' || i; end if;
      if exists(select 1 from jsonb_array_elements_text(q->'o') x where length(btrim(x)) < 1 or length(x) > 300) then return 'opts:' || i; end if;
      if k = 'one' then
        if jsonb_typeof(q->'a') <> 'number' or (q->>'a')::int < 0 or (q->>'a')::int >= n then return 'answer:' || i; end if;
      else
        if jsonb_typeof(q->'a') <> 'array' or jsonb_array_length(q->'a') < 1
          or exists(select 1 from jsonb_array_elements(q->'a') x where jsonb_typeof(x) <> 'number' or x::text::int < 0 or x::text::int >= n) then return 'answer:' || i; end if;
      end if;
    elsif k = 'num' then
      if q ? 'v' and jsonb_typeof(q->'v') = 'object' and q->'v' <> '{}'::jsonb then
        if jsonb_typeof(q->'a') <> 'string' then return 'answer:' || i; end if;
        vals := '{}';
        for v in select value from jsonb_each(q->'v') loop
          if jsonb_typeof(v) <> 'array' or jsonb_array_length(v) <> 3 or exists(select 1 from jsonb_array_elements(v) z where jsonb_typeof(z) <> 'number') then return 'vars:' || i; end if;
        end loop;
        if exists(select 1 from jsonb_object_keys(q->'v') x where x !~ '^[a-z][a-z0-9_]{0,9}$') then return 'vars:' || i; end if;
        select jsonb_object_agg(key, (value->>0)::numeric) into vals from jsonb_each(q->'v');
        if lab.calc(q->>'a', vals) is null then return 'formula:' || i; end if;
      elsif jsonb_typeof(q->'a') <> 'number' then return 'answer:' || i; end if;
      if q ? 'tol' and (jsonb_typeof(q->'tol') <> 'number' or (q->>'tol')::float8 < 0 or (q->>'tol')::float8 > 50) then return 'tol:' || i; end if;
    elsif k = 'text' then
      if jsonb_typeof(q->'a') <> 'array' or jsonb_array_length(q->'a') < 1
        or exists(select 1 from jsonb_array_elements_text(q->'a') x where length(btrim(x)) < 1) then return 'answer:' || i; end if;
    else return 'kind:' || i; end if;
  end loop;
  return null;
end $$;

-- случайное значение переменной: [от, до, шаг]
create or replace function lab.rand_val(r jsonb) returns numeric language plpgsql volatile set search_path = '' as $$
declare a numeric := (r->>0)::numeric; b numeric := (r->>1)::numeric; s numeric := nullif((r->>2)::numeric, 0); n int;
begin
  if s is null or b <= a then return a; end if;
  n := floor((b - a) / s)::int;
  return a + s * floor(random() * (n + 1));
end $$;

-- выставить оценку попытке (по сохранённым ответам)
create or replace function lab.grade(p_attempt uuid) returns jsonb language plpgsql set search_path = '' as $$
declare at lab.attempts; t lab.tests; p jsonb; q jsonb; ans jsonb; i int := 0; ok boolean; sc int := 0; det jsonb := '[]'; given jsonb; x float8; c float8; tol float8;
begin
  select * into at from lab.attempts where id = p_attempt for update;
  if at.id is null then return null; end if;
  select * into t from lab.tests where id = at.test_id;
  for p in select value from jsonb_array_elements(at.plan) loop
    q := t.qs->((p->>'i')::int); ans := at.answers->(i::text); ok := false; given := null;
    if q is not null and ans is not null and ans <> 'null'::jsonb then
      if q->>'k' = 'one' then
        if (case when ans::text ~ '^[0-9]{1,2}$' then (ans::text)::int else -1 end) between 0 and jsonb_array_length(p->'p') - 1 then
          given := p->'p'->((ans::text)::int); ok := given = q->'a'; end if;
      elsif q->>'k' = 'many' then
        if jsonb_typeof(ans) = 'array' then
          select coalesce(jsonb_agg(p->'p'->((s.xv::text)::int) order by (p->'p'->((s.xv::text)::int))::text::int), '[]') into given
            from (select distinct value as xv from jsonb_array_elements(ans) where (case when value::text ~ '^[0-9]{1,2}$' then (value::text)::int else -1 end) between 0 and jsonb_array_length(p->'p') - 1) s;
          ok := given = (select jsonb_agg(v order by v::text::int) from jsonb_array_elements(q->'a') v);
        end if;
      elsif q->>'k' = 'num' then
        x := lab.num(ans #>> '{}'); given := to_jsonb(ans #>> '{}');
        c := coalesce((p->>'c')::float8, (q->>'a')::float8); tol := coalesce((q->>'tol')::float8, 1);
        ok := x is not null and c is not null and abs(x - c) <= abs(c) * tol / 100 + 1e-9;
      elsif q->>'k' = 'text' then
        given := to_jsonb(ans #>> '{}');
        ok := exists(select 1 from jsonb_array_elements_text(q->'a') v where lab.norm(v) = lab.norm(ans #>> '{}'));
      end if;
    end if;
    if ok then sc := sc + 1; end if;
    det := det || jsonb_build_object('i', (p->>'i')::int, 'ok', ok, 'g', given);
    i := i + 1;
  end loop;
  update lab.attempts set score = sc, max = jsonb_array_length(at.plan), finished_at = coalesce(finished_at, least(now(), ends_at)) where id = at.id;
  return jsonb_build_object('score', sc, 'max', jsonb_array_length(at.plan), 'det', det);
end $$;

-- вопросы попытки для ученика: без правильных ответов, варианты в перемешанном порядке
create or replace function lab.attempt_view(at lab.attempts) returns jsonb language sql stable set search_path = '' as $$
  select jsonb_build_object('attempt', at.id, 'title', t.title, 'ends', at.ends_at, 'now', now(), 'answers', at.answers, 'leaves', at.leaves,
    'qs', (select jsonb_agg(jsonb_build_object('k', q->>'k',
        't', (select coalesce((select string_agg(part, '') from (select case when m[1] is not null and p->'vals' ? m[1] then p->'vals'->>m[1] else m[2] end as part, n
               from regexp_matches(q->>'t', '\{([a-z][a-z0-9_]*)\}|([^{]+|\{)', 'g') with ordinality as r(m, n) order by n) z), q->>'t')),
        'o', case when q->>'k' in ('one','many') then (select jsonb_agg(q->'o'->((x::text)::int) order by n) from jsonb_array_elements(p->'p') with ordinality as y(x, n)) end,
        'many', q->>'k' = 'many') order by pn)
      from jsonb_array_elements(at.plan) with ordinality as pp(p, pn), lateral (select t.qs->((p->>'i')::int) as q) qq))
  from lab.tests t where t.id = at.test_id $$;

-- ===== API: учитель
create or replace function public.t_tests(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('tests', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'minutes', x.minutes, 'pick', x.pick, 'n', jsonb_array_length(x.qs),
      'used', exists(select 1 from lab.attempts a where a.test_id = x.id), 'updated', x.updated_at) order by x.updated_at desc), '[]'::jsonb) from lab.tests x where x.teacher_id = t.id));
end $$;

create or replace function public.t_test_get(p_token text, p_test uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); x lab.tests;
begin
  select * into x from lab.tests where id = p_test and teacher_id = t.id;
  if x.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('id', x.id, 'title', x.title, 'minutes', x.minutes, 'pick', x.pick, 'qs', x.qs, 'used', exists(select 1 from lab.attempts a where a.test_id = x.id));
end $$;

create or replace function public.t_test_save(p_token text, p_test uuid, p_title text, p_minutes int, p_pick int, p_qs jsonb) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); nm text := lab.clean_name(p_title, 120); e text; tid uuid; n int;
begin
  if t.id is null then return jsonb_build_object('err', 'session'); end if;
  if length(nm) < 1 then return jsonb_build_object('err', 'title'); end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 180 then return jsonb_build_object('err', 'minutes'); end if;
  e := lab.check_qs(p_qs); if e is not null then return jsonb_build_object('err', 'qs', 'what', e); end if;
  n := jsonb_array_length(p_qs);
  if p_pick is not null and (p_pick < 1 or p_pick > n) then return jsonb_build_object('err', 'pick'); end if;
  if p_test is null then
    if (select count(*) from lab.tests where teacher_id = t.id) >= 200 then return jsonb_build_object('err', 'limit'); end if;
    insert into lab.tests(teacher_id, title, minutes, pick, qs) values (t.id, nm, p_minutes, nullif(p_pick, n), p_qs) returning id into tid;
  else
    select id into tid from lab.tests where id = p_test and teacher_id = t.id;
    if tid is null then return jsonb_build_object('err', 'session'); end if;
    if exists(select 1 from lab.attempts where test_id = tid) and (select qs from lab.tests where id = tid) <> p_qs then return jsonb_build_object('err', 'used'); end if;
    update lab.tests set title = nm, minutes = p_minutes, pick = nullif(p_pick, n), qs = p_qs, updated_at = now() where id = tid;
  end if;
  return jsonb_build_object('id', tid);
end $$;

create or replace function public.t_test_delete(p_token text, p_test uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token);
begin
  if t.id is null or not exists(select 1 from lab.tests where id = p_test and teacher_id = t.id) then return jsonb_build_object('err', 'session'); end if;
  perform lab.del_test(p_test);
  return jsonb_build_object('ok', true);
end $$;

create or replace function lab.class_tests_json(p_class uuid) returns jsonb language sql stable set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('test', ct.test_id, 'title', x.title, 'deadline', ct.deadline,
    'done', (select count(*) from lab.attempts a where a.class_id = p_class and a.test_id = ct.test_id and (a.finished_at is not null or a.ends_at < now()))) order by ct.opened_at), '[]'::jsonb)
  from lab.class_tests ct join lab.tests x on x.id = ct.test_id where ct.class_id = p_class $$;

create or replace function public.t_class_tests(p_token text, p_class uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object('tests', lab.class_tests_json(c.id));
end $$;

create or replace function public.t_test_set(p_token text, p_class uuid, p_test uuid, p_open boolean, p_deadline timestamptz) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class);
begin
  if c.id is null or not exists(select 1 from lab.tests where id = p_test and teacher_id = c.teacher_id) then return jsonb_build_object('err', 'session'); end if;
  if p_open then
    insert into lab.class_tests(class_id, test_id, deadline) values (c.id, p_test, p_deadline)
      on conflict (class_id, test_id) do update set deadline = excluded.deadline;
  else
    perform lab.del_class_test(c.id, p_test);
  end if;
  return jsonb_build_object('tests', lab.class_tests_json(c.id));
end $$;

-- результаты теста в классе: незавершённые попытки с истёкшим временем сначала оцениваются
create or replace function public.t_test_results(p_token text, p_class uuid, p_test uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare c lab.classes := lab.my_class(p_token, p_class); ar record; det jsonb := '{}'; g jsonb;
begin
  if c.id is null then return jsonb_build_object('err', 'session'); end if;
  for ar in select id from lab.attempts where class_id = c.id and test_id = p_test and (finished_at is not null or ends_at < now()) loop
    g := lab.grade(ar.id);
    det := det || jsonb_build_object(ar.id::text, g->'det');
  end loop;
  return jsonb_build_object('test', (select jsonb_build_object('id', x.id, 'title', x.title, 'minutes', x.minutes, 'qs', x.qs) from lab.tests x where x.id = p_test),
    'attempts', (select coalesce(jsonb_agg(jsonb_build_object('student', a.student_id, 'name', s.name, 'started', a.started_at, 'finished', a.finished_at, 'ends', a.ends_at,
        'active', a.ends_at > now() and a.finished_at is null, 'score', a.score, 'max', a.max, 'leaves', a.leaves, 'det', det->(a.id::text)) order by s.name), '[]'::jsonb)
      from lab.attempts a join lab.students s on s.id = a.student_id where a.class_id = c.id and a.test_id = p_test),
    'now', now());
end $$;

-- ===== API: ученик
create or replace function public.s_tests(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students;
begin
  if s.token is null then return jsonb_build_object('err', 'session'); end if;
  if s.kind <> 's' then return jsonb_build_object('tests', '[]'::jsonb); end if;
  select * into st from lab.students where id = s.student_id;
  return jsonb_build_object('tests', (select coalesce(jsonb_agg(jsonb_build_object('id', x.id, 'title', x.title, 'minutes', x.minutes,
      'n', coalesce(x.pick, jsonb_array_length(x.qs)), 'deadline', ct.deadline,
      'state', case when a.id is null then (case when ct.deadline is not null and ct.deadline < now() then 'late' else 'new' end)
                    when a.finished_at is not null or a.ends_at < now() then 'done' else 'active' end,
      'score', a.score, 'max', a.max) order by ct.opened_at), '[]'::jsonb)
    from lab.class_tests ct join lab.tests x on x.id = ct.test_id
    left join lab.attempts a on a.test_id = x.id and a.student_id = st.id
    where ct.class_id = st.class_id), 'now', now());
end $$;

create or replace function public.s_test_start(p_token text, p_test uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); st lab.students; ct lab.class_tests; x lab.tests; at lab.attempts; plan jsonb := '[]'; q record; vals jsonb; p jsonb; n int;
begin
  if s.token is null or s.kind <> 's' then return jsonb_build_object('err', 'session'); end if;
  select * into st from lab.students where id = s.student_id;
  select * into ct from lab.class_tests where class_id = st.class_id and test_id = p_test;
  if ct.test_id is null then return jsonb_build_object('err', 'closed'); end if;
  select * into at from lab.attempts where test_id = p_test and student_id = st.id for update;
  if at.id is not null then
    if at.finished_at is not null or at.ends_at < now() then perform lab.grade(at.id); return jsonb_build_object('err', 'done'); end if;
    return lab.attempt_view(at);
  end if;
  if ct.deadline is not null and ct.deadline < now() then return jsonb_build_object('err', 'late'); end if;
  select * into x from lab.tests where id = p_test;
  n := coalesce(x.pick, jsonb_array_length(x.qs));
  for q in select (o - 1)::int as i, v from jsonb_array_elements(x.qs) with ordinality as e(v, o) order by random() limit n loop
    vals := null; p := null;
    if q.v->>'k' in ('one', 'many') then
      select jsonb_agg(g - 1 order by random()) into p from generate_series(1, jsonb_array_length(q.v->'o')) g;
    end if;
    if q.v->>'k' = 'num' and q.v ? 'v' and q.v->'v' <> '{}'::jsonb then
      select jsonb_object_agg(key, lab.rand_val(value)) into vals from jsonb_each(q.v->'v');
    end if;
    plan := plan || jsonb_build_object('i', q.i, 'p', p, 'vals', vals, 'c', case when vals is not null then to_jsonb(lab.calc(q.v->>'a', vals)) end);
  end loop;
  insert into lab.attempts(test_id, class_id, student_id, ends_at, plan)
    values (p_test, st.class_id, st.id, least(now() + make_interval(mins => x.minutes), coalesce(ct.deadline, 'infinity'::timestamptz)), plan) returning * into at;
  return lab.attempt_view(at);
end $$;

-- сохранить ответы (каждое изменение); после конца времени ответы не принимаются
create or replace function public.s_test_save(p_token text, p_attempt uuid, p_answers jsonb, p_leaves int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); at lab.attempts;
begin
  if s.token is null or s.kind <> 's' then return jsonb_build_object('err', 'session'); end if;
  select * into at from lab.attempts where id = p_attempt and student_id = s.student_id for update;
  if at.id is null then return jsonb_build_object('err', 'session'); end if;
  if at.finished_at is not null or at.ends_at + interval '10 seconds' < now() then return jsonb_build_object('err', 'done'); end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'object' or length(p_answers::text) > 20000 then return jsonb_build_object('err', 'data'); end if;
  update lab.attempts set answers = p_answers, leaves = greatest(leaves, least(coalesce(p_leaves, 0), 1000)) where id = at.id;
  return jsonb_build_object('ok', true, 'ends', at.ends_at, 'now', now());
end $$;

create or replace function public.s_test_finish(p_token text, p_attempt uuid, p_answers jsonb, p_leaves int) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare s lab.sessions := lab.sess(p_token); at lab.attempts; g jsonb;
begin
  if s.token is null or s.kind <> 's' then return jsonb_build_object('err', 'session'); end if;
  select * into at from lab.attempts where id = p_attempt and student_id = s.student_id for update;
  if at.id is null then return jsonb_build_object('err', 'session'); end if;
  if at.finished_at is null and at.ends_at + interval '10 seconds' >= now() and p_answers is not null and jsonb_typeof(p_answers) = 'object' and length(p_answers::text) <= 20000 then
    update lab.attempts set answers = p_answers, leaves = greatest(leaves, least(coalesce(p_leaves, 0), 1000)) where id = at.id;
  end if;
  update lab.attempts set finished_at = least(now(), ends_at) where id = at.id and finished_at is null;
  g := lab.grade(at.id);
  return jsonb_build_object('score', g->'score', 'max', g->'max');
end $$;

revoke all on all functions in schema lab from public, anon, authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname in ('t_tests','t_test_get','t_test_save','t_test_delete','t_class_tests','t_test_set','t_test_results',
      's_tests','s_test_start','s_test_save','s_test_finish')
  loop
    execute format('revoke all on function %s from public', f.sig);
    if exists(select 1 from pg_roles where rolname = 'anon') then execute format('grant execute on function %s to anon, authenticated', f.sig); end if;
  end loop;
end $$;
