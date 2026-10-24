-- Rode isto uma vez se o banco já foi criado com a versão anterior do setup.
-- O acesso passa a ser usuário admin e senha admin.
-- O número de times passa a 4 e os jogadores por time a 6. O raio e o local do campo não mudam.

alter table parametros add column if not exists admin_usuario text;

update parametros
set admin_usuario = 'admin',
    admin_pin_hash = extensions.crypt('admin', extensions.gen_salt('bf')),
    num_times = 4,
    jogadores_por_time = 6
where id = 1;

alter table parametros alter column admin_usuario set not null;
alter table parametros alter column num_times set default 4;
alter table parametros alter column jogadores_por_time set default 6;

drop function if exists public.senha_confere(text);
drop function if exists public.salvar_parametros(text, double precision, double precision, double precision, int, int, int, boolean);
drop function if exists public.novo_jogo(text);

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

notify pgrst, 'reload schema';

