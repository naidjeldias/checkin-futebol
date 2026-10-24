-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- Usuário e senha iniciais do administrador: admin / admin.
-- Troque os dois só no insert abaixo, no editor do Supabase, se quiser outros valores.
-- A página mostra os horários em America/Sao_Paulo (constante FUSO em app.js).

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table parametros (
  id int primary key,
  lat double precision,
  lng double precision,
  raio_m int not null default 200,
  num_times int not null default 4,
  jogadores_por_time int not null default 6,
  admin_usuario text not null,
  admin_pin_hash text not null,
  constraint parametros_uma_linha check (id = 1),
  constraint parametros_raio check (raio_m between 10 and 2000),
  constraint parametros_times check (num_times between 2 and 10),
  constraint parametros_jogadores check (jogadores_por_time between 1 and 15),
  constraint parametros_local check (
    (lat is null and lng is null)
    or (lat between -90 and 90 and lng between -180 and 180)
  )
);

insert into parametros (id, raio_m, num_times, jogadores_por_time, admin_usuario, admin_pin_hash)
values (
  1,
  200,
  4,
  6,
  'admin',
  extensions.crypt('admin', extensions.gen_salt('bf'))
);

create table checkins (
  id bigint generated always as identity primary key,
  nome text not null,
  nome_norm text not null unique,
  goleiro boolean not null default false,
  created_at timestamptz not null default now()
);

create index checkins_ordem on checkins (created_at, id);

create table sorteio (
  id bigint generated always as identity primary key,
  created_at timestamptz not null default now(),
  num_times int not null,
  jogadores_por_time int not null
);

create table sorteio_jogadores (
  sorteio_id bigint not null references sorteio (id) on delete cascade,
  checkin_id bigint not null references checkins (id) on delete cascade,
  time_num int not null check (time_num >= 1),
  posicao int not null check (posicao >= 1),
  primary key (sorteio_id, checkin_id),
  unique (sorteio_id, time_num, posicao)
);

create or replace function public.nome_normalizado(p_nome text)
returns text
language sql
immutable
as $$
  select translate(
    lower(p_nome),
    'áàâãäåéèêëíìîïóòôõöúùûüýÿçñ',
    'aaaaaaeeeeiiiioooooouuuuyycn'
  );
$$;

create or replace function public.distancia_m(
  p_lat1 double precision,
  p_lng1 double precision,
  p_lat2 double precision,
  p_lng2 double precision
)
returns double precision
language sql
immutable
as $$
  select 6371000 * 2 * asin(
    sqrt(
      power(sin(radians(p_lat2 - p_lat1) / 2), 2)
      + cos(radians(p_lat1)) * cos(radians(p_lat2))
        * power(sin(radians(p_lng2 - p_lng1) / 2), 2)
    )
  );
$$;

-- Uso interno. A página chama verificar_local e checkin.
create or replace function public.avaliar_local(
  p_lat double precision,
  p_lng double precision,
  p_precisao double precision
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_lat double precision;
  v_lng double precision;
  v_raio int;
  v_dist double precision;
begin
  if p_lat is null or p_lng is null
     or p_lat <> p_lat or p_lng <> p_lng
     or p_lat < -90 or p_lat > 90
     or p_lng < -180 or p_lng > 180 then
    return jsonb_build_object('ok', false, 'erro', 'local_invalido');
  end if;

  if p_precisao is null or p_precisao <> p_precisao or p_precisao < 0 or p_precisao > 100 then
    return jsonb_build_object(
      'ok', false,
      'erro', 'gps_impreciso',
      'precisao_m', round(coalesce(p_precisao, 0))::int
    );
  end if;

  select lat, lng, raio_m
    into v_lat, v_lng, v_raio
  from parametros
  where id = 1;

  if v_lat is null or v_lng is null then
    return jsonb_build_object('ok', false, 'erro', 'campo_indefinido');
  end if;

  v_dist := distancia_m(p_lat, p_lng, v_lat, v_lng);

  if v_dist > v_raio then
    return jsonb_build_object(
      'ok', false,
      'erro', 'longe',
      'distancia_m', round(v_dist)::int,
      'raio_m', v_raio
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'distancia_m', round(v_dist)::int,
    'raio_m', v_raio
  );
end;
$$;

create or replace function public.posicao_de(p_id bigint)
returns int
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::int
  from checkins c
  join checkins alvo on alvo.id = p_id
  where c.created_at < alvo.created_at
     or (c.created_at = alvo.created_at and c.id <= alvo.id);
$$;

create or replace function public.ler_parametros()
returns table (
  campo_definido boolean,
  raio_m int,
  num_times int,
  jogadores_por_time int
)
language sql
stable
security definer
set search_path = public
as $$
  select
    lat is not null and lng is not null,
    raio_m,
    num_times,
    jogadores_por_time
  from parametros
  where id = 1;
$$;

create or replace function public.verificar_local(
  p_lat double precision,
  p_lng double precision,
  p_precisao double precision
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select avaliar_local(p_lat, p_lng, p_precisao);
$$;

create or replace function public.checkin(
  p_nome text,
  p_lat double precision,
  p_lng double precision,
  p_precisao double precision,
  p_goleiro boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_nome text;
  v_norm text;
  v_local jsonb;
  v_id bigint;
  v_created timestamptz;
  v_exist_id bigint;
begin
  v_nome := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');

  if char_length(v_nome) < 2
     or char_length(v_nome) > 40
     or v_nome !~ '[[:alpha:]]' then
    return jsonb_build_object('ok', false, 'erro', 'nome_invalido');
  end if;

  v_norm := nome_normalizado(v_nome);

  select id into v_exist_id
  from checkins
  where nome_norm = v_norm;

  if v_exist_id is not null then
    return jsonb_build_object(
      'ok', true,
      'ja_existia', true,
      'posicao', posicao_de(v_exist_id),
      'nome', (select nome from checkins where id = v_exist_id)
    );
  end if;

  v_local := avaliar_local(p_lat, p_lng, p_precisao);
  if not (v_local ->> 'ok')::boolean then
    return v_local;
  end if;

  insert into checkins (nome, nome_norm, goleiro)
  values (v_nome, v_norm, coalesce(p_goleiro, false))
  returning id, created_at into v_id, v_created;

  return jsonb_build_object(
    'ok', true,
    'ja_existia', false,
    'posicao', posicao_de(v_id),
    'nome', v_nome
  );
exception
  when unique_violation then
    select id into v_exist_id
    from checkins
    where nome_norm = v_norm;

    return jsonb_build_object(
      'ok', true,
      'ja_existia', true,
      'posicao', posicao_de(v_exist_id),
      'nome', (select nome from checkins where id = v_exist_id)
    );
end;
$$;

create or replace function public.credenciais_conferem(p_usuario text, p_senha text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p_usuario is not null
     and p_senha is not null
     and p_senha <> ''
     and lower(trim(p_usuario)) = lower(admin_usuario)
     and admin_pin_hash = extensions.crypt(p_senha, admin_pin_hash)
  from parametros
  where id = 1;
$$;

create or replace function public.entrar_admin(p_usuario text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not credenciais_conferem(p_usuario, p_senha) then
    return jsonb_build_object('ok', false, 'erro', 'credenciais_invalidas');
  end if;

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.salvar_parametros(
  p_usuario text,
  p_senha text,
  p_lat double precision,
  p_lng double precision,
  p_precisao double precision,
  p_raio_m int,
  p_num_times int,
  p_jogadores_por_time int,
  p_atualizar_local boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not credenciais_conferem(p_usuario, p_senha) then
    return jsonb_build_object('ok', false, 'erro', 'credenciais_invalidas');
  end if;

  if p_raio_m is null or p_raio_m < 10 or p_raio_m > 2000 then
    return jsonb_build_object('ok', false, 'erro', 'raio_invalido');
  end if;

  if p_num_times is null or p_num_times < 2 or p_num_times > 10 then
    return jsonb_build_object('ok', false, 'erro', 'times_invalidos');
  end if;

  if p_jogadores_por_time is null
     or p_jogadores_por_time < 1
     or p_jogadores_por_time > 15 then
    return jsonb_build_object('ok', false, 'erro', 'jogadores_invalidos');
  end if;

  if coalesce(p_atualizar_local, false) then
    if p_precisao is null or p_precisao <> p_precisao or p_precisao < 0 or p_precisao > 100 then
      return jsonb_build_object('ok', false, 'erro', 'gps_impreciso');
    end if;

    if p_lat is null or p_lng is null
       or p_lat <> p_lat or p_lng <> p_lng
       or p_lat < -90 or p_lat > 90
       or p_lng < -180 or p_lng > 180 then
      return jsonb_build_object('ok', false, 'erro', 'local_invalido');
    end if;

    update parametros
    set lat = p_lat,
        lng = p_lng,
        raio_m = p_raio_m,
        num_times = p_num_times,
        jogadores_por_time = p_jogadores_por_time
    where id = 1;
  else
    update parametros
    set raio_m = p_raio_m,
        num_times = p_num_times,
        jogadores_por_time = p_jogadores_por_time
    where id = 1;
  end if;

  return jsonb_build_object('ok', true, 'local_atualizado', coalesce(p_atualizar_local, false));
end;
$$;

create or replace function public.sugerir_times()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_times int;
  v_por_time int;
  v_vagas int;
  v_ids bigint[];
  v_gks boolean[];
  v_sel_ids bigint[] := array[]::bigint[];
  v_sel_gk boolean[] := array[]::boolean[];
  v_gk_n int := 0;
  v_i int;
  v_sorteio_id bigint;
  v_gk_ids bigint[];
  v_linha_ids bigint[];
  v_teams int[];
begin
  select num_times, jogadores_por_time
    into v_times, v_por_time
  from parametros
  where id = 1;

  if v_times is null then
    return jsonb_build_object('ok', false, 'erro', 'sem_parametros');
  end if;

  v_vagas := v_times * v_por_time;

  select
    coalesce(array_agg(id order by created_at, id), array[]::bigint[]),
    coalesce(array_agg(goleiro order by created_at, id), array[]::boolean[])
    into v_ids, v_gks
  from checkins;

  for v_i in 1 .. coalesce(array_length(v_ids, 1), 0) loop
    exit when coalesce(array_length(v_sel_ids, 1), 0) >= v_vagas;

    if v_gks[v_i] then
      if v_gk_n >= v_times then
        continue;
      end if;
      v_gk_n := v_gk_n + 1;
    end if;

    v_sel_ids := array_append(v_sel_ids, v_ids[v_i]);
    v_sel_gk := array_append(v_sel_gk, v_gks[v_i]);
  end loop;

  delete from sorteio;

  insert into sorteio (created_at, num_times, jogadores_por_time)
  values (now(), v_times, v_por_time)
  returning id into v_sorteio_id;

  select coalesce(array_agg(s.id order by random()), array[]::bigint[])
    into v_gk_ids
  from generate_subscripts(v_sel_ids, 1) as i
  cross join lateral (
    select v_sel_ids[i] as id, v_sel_gk[i] as gk
  ) as s
  where s.gk;

  select coalesce(array_agg(s.id order by random()), array[]::bigint[])
    into v_linha_ids
  from generate_subscripts(v_sel_ids, 1) as i
  cross join lateral (
    select v_sel_ids[i] as id, v_sel_gk[i] as gk
  ) as s
  where not s.gk;

  select coalesce(array_agg(t order by random()), array[]::int[])
    into v_teams
  from generate_series(1, v_times) as t;

  for v_i in 1 .. coalesce(array_length(v_gk_ids, 1), 0) loop
    insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
    values (v_sorteio_id, v_gk_ids[v_i], v_teams[v_i], 1);
  end loop;

  with slots as (
    select t.time_num, p.pos
    from generate_series(1, v_times) as t(time_num)
    cross join generate_series(1, v_por_time) as p(pos)
    where not exists (
      select 1
      from sorteio_jogadores j
      where j.sorteio_id = v_sorteio_id
        and j.time_num = t.time_num
        and j.posicao = p.pos
    )
  ),
  slots_rand as (
    select time_num, pos, row_number() over (order by random()) as rn
    from slots
  ),
  linhas as (
    select id, row_number() over (order by random()) as rn
    from unnest(v_linha_ids) as id
  )
  insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
  select v_sorteio_id, l.id, s.time_num, s.pos
  from linhas l
  join slots_rand s on s.rn = l.rn;

  return jsonb_build_object(
    'ok', true,
    'convocados', coalesce(array_length(v_sel_ids, 1), 0),
    'goleiros', coalesce(array_length(v_gk_ids, 1), 0)
  );
end;
$$;

create or replace function public.novo_jogo(p_usuario text, p_senha text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not credenciais_conferem(p_usuario, p_senha) then
    return jsonb_build_object('ok', false, 'erro', 'credenciais_invalidas');
  end if;

  delete from checkins;
  delete from sorteio;

  return jsonb_build_object('ok', true);
end;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
end $$;

revoke all on function public.nome_normalizado(text) from public;
revoke all on function public.distancia_m(double precision, double precision, double precision, double precision) from public;
revoke all on function public.avaliar_local(double precision, double precision, double precision) from public;
revoke all on function public.posicao_de(bigint) from public;
revoke all on function public.credenciais_conferem(text, text) from public;
revoke all on function public.entrar_admin(text, text) from public;

revoke all on function public.ler_parametros() from public;
revoke all on function public.verificar_local(double precision, double precision, double precision) from public;
revoke all on function public.checkin(text, double precision, double precision, double precision, boolean) from public;
revoke all on function public.salvar_parametros(text, text, double precision, double precision, double precision, int, int, int, boolean) from public;
revoke all on function public.sugerir_times() from public;
revoke all on function public.novo_jogo(text, text) from public;

grant execute on function public.entrar_admin(text, text) to anon, authenticated;
grant execute on function public.ler_parametros() to anon, authenticated;
grant execute on function public.verificar_local(double precision, double precision, double precision) to anon, authenticated;
grant execute on function public.checkin(text, double precision, double precision, double precision, boolean) to anon, authenticated;
grant execute on function public.salvar_parametros(text, text, double precision, double precision, double precision, int, int, int, boolean) to anon, authenticated;
grant execute on function public.sugerir_times() to anon, authenticated;
grant execute on function public.novo_jogo(text, text) to anon, authenticated;

grant select on checkins to anon, authenticated;
grant select on sorteio to anon, authenticated;
grant select on sorteio_jogadores to anon, authenticated;

alter table parametros enable row level security;
alter table checkins enable row level security;
alter table sorteio enable row level security;
alter table sorteio_jogadores enable row level security;

create policy checkins_leitura on checkins
  for select to anon, authenticated
  using (true);

create policy sorteio_leitura on sorteio
  for select to anon, authenticated
  using (true);

create policy sorteio_jogadores_leitura on sorteio_jogadores
  for select to anon, authenticated
  using (true);

do $$
begin
  alter publication supabase_realtime add table checkins;
  alter publication supabase_realtime add table sorteio;
  alter publication supabase_realtime add table sorteio_jogadores;
exception
  when undefined_object then
    raise notice 'A publicação supabase_realtime não foi encontrada.';
end $$;

notify pgrst, 'reload schema';
