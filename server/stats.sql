-- Лаборатория Сириус: простой счётчик посещений без личных данных.
-- Браузер хранит случайный номер посетителя (не связан с именем, IP не сохраняется)
-- и при открытии страницы сообщает её раздел. Статистику видят только администраторы.

create table if not exists lab.visits(
  day date not null,
  vid text not null,
  views int not null default 1,
  mobile boolean not null default false,
  lang text not null default 'ru',
  primary key(day, vid));

create table if not exists lab.page_hits(
  day date not null,
  page text not null,
  n int not null default 1,
  primary key(day, page));

alter table lab.visits enable row level security;
alter table lab.page_hits enable row level security;

create or replace function public.hit(p_vid text, p_page text, p_mobile boolean, p_lang text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare d date := (now() at time zone 'Europe/Moscow')::date; pg text := left(lower(coalesce(p_page, '')), 40); v int;
begin
  if coalesce(p_vid, '') !~ '^[0-9a-f]{16,64}$' then return jsonb_build_object('ok', false); end if;
  if pg !~ '^[a-z0-9/_-]*$' then pg := 'other'; end if;
  if pg = '' then pg := 'home'; end if;
  insert into lab.visits(day, vid, mobile, lang) values (d, p_vid, coalesce(p_mobile, false), case when p_lang = 'en' then 'en' else 'ru' end)
    on conflict (day, vid) do update set views = lab.visits.views + 1
    returning views into v;
  if v <= 300 then
    insert into lab.page_hits(day, page) values (d, pg) on conflict (day, page) do update set n = lab.page_hits.n + 1;
  end if;
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.a_stats(p_token text) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare t lab.teachers := lab.teacher(p_token); d date := (now() at time zone 'Europe/Moscow')::date;
begin
  if t.id is null or not t.is_admin then return jsonb_build_object('err', 'session'); end if;
  return jsonb_build_object(
    'today', (select jsonb_build_object('visitors', count(*), 'views', coalesce(sum(views), 0)) from lab.visits where day = d),
    'week', (select jsonb_build_object('visitors', count(distinct vid), 'views', coalesce(sum(views), 0)) from lab.visits where day > d - 7),
    'month', (select jsonb_build_object('visitors', count(distinct vid), 'views', coalesce(sum(views), 0)) from lab.visits where day > d - 30),
    'total', (select jsonb_build_object('visitors', count(distinct vid), 'views', coalesce(sum(views), 0), 'since', min(day)) from lab.visits),
    'mobile', (select round(100.0 * count(*) filter (where mobile) / greatest(count(*), 1)) from lab.visits where day > d - 30),
    'en', (select round(100.0 * count(*) filter (where lang = 'en') / greatest(count(*), 1)) from lab.visits where day > d - 30),
    'days', (select coalesce(jsonb_agg(jsonb_build_object('day', g::date, 'visitors', (select count(*) from lab.visits v where v.day = g::date)) order by g), '[]'::jsonb)
      from generate_series(d - 29, d, interval '1 day') g),
    'pages', (select coalesce(jsonb_agg(jsonb_build_object('page', page, 'n', n) order by n desc), '[]'::jsonb)
      from (select page, sum(n) as n from lab.page_hits where day > d - 30 group by page order by 2 desc limit 15) p));
end $$;

revoke all on function public.hit(text, text, boolean, text) from public;
revoke all on function public.a_stats(text) from public;
do $$ begin
  if exists(select 1 from pg_roles where rolname = 'anon') then
    grant execute on function public.hit(text, text, boolean, text) to anon, authenticated;
    grant execute on function public.a_stats(text) to anon, authenticated;
  end if;
end $$;
