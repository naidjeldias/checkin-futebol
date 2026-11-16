-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- Os times enchem da frente para trás. Quem chegou antes é sorteado
-- só entre os times completos. O último time fica com quem chegou
-- por último e com as vagas. Este arquivo não dispara um sorteio novo.

-- Depois do sorteio, coloca quem ainda não tem time nas vagas que sobrarem.
-- Quem já está num time não muda. As vagas enchem da frente para trás.
-- Goleiro só entra em time que ainda não tem goleiro.
create or replace function public.completar_sorteio()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sorteio_id bigint;
  v_times int;
  v_por_time int;
  v_fila record;
  v_no_time int[];
  v_tem_gk boolean[];
  v_i int;
  v_time int;
  v_posicao int;
  v_colocados int := 0;
begin
  select id, num_times, jogadores_por_time
    into v_sorteio_id, v_times, v_por_time
  from sorteio
  order by created_at desc, id desc
  limit 1
  for update;

  if v_sorteio_id is null or v_times is null or v_por_time is null then
    return jsonb_build_object('ok', true, 'colocados', 0);
  end if;

  v_no_time := array_fill(0, array[v_times]);
  v_tem_gk := array_fill(false, array[v_times]);

  for v_fila in
    select sj.time_num, c.goleiro
    from sorteio_jogadores sj
    join checkins c on c.id = sj.checkin_id
    where sj.sorteio_id = v_sorteio_id
      and sj.time_num between 1 and v_times
  loop
    v_no_time[v_fila.time_num] := v_no_time[v_fila.time_num] + 1;
    if v_fila.goleiro then
      v_tem_gk[v_fila.time_num] := true;
    end if;
  end loop;

  for v_fila in
    select c.id, c.goleiro
    from checkins c
    where not exists (
      select 1
      from sorteio_jogadores sj
      where sj.sorteio_id = v_sorteio_id
        and sj.checkin_id = c.id
    )
    order by c.created_at, c.id
  loop
    v_time := null;

    for v_i in 1 .. v_times loop
      if v_no_time[v_i] >= v_por_time then
        continue;
      end if;
      if v_fila.goleiro and v_tem_gk[v_i] then
        continue;
      end if;
      v_time := v_i;
      exit;
    end loop;

    if v_time is null then
      continue;
    end if;

    select coalesce(max(posicao), 0) + 1
      into v_posicao
    from sorteio_jogadores
    where sorteio_id = v_sorteio_id
      and time_num = v_time;

    insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
    values (v_sorteio_id, v_fila.id, v_time, v_posicao);

    v_no_time[v_time] := v_no_time[v_time] + 1;
    if v_fila.goleiro then
      v_tem_gk[v_time] := true;
    end if;
    v_colocados := v_colocados + 1;
  end loop;

  return jsonb_build_object('ok', true, 'colocados', v_colocados);
end;
$$;

-- Sorteia quem chegou antes entre os times que ficam completos.
-- O último time fica com quem chegou por último e com as vagas.
-- Cada time fica com no máximo um goleiro. Se o time sorteado já tem
-- goleiro, ele vai para o próximo time sem goleiro e um jogador de linha
-- que chegou depois preenche a vaga.
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
  v_front_ids bigint[] := array[]::bigint[];
  v_front_gk boolean[] := array[]::boolean[];
  v_back_ids bigint[] := array[]::bigint[];
  v_back_gk boolean[] := array[]::boolean[];
  v_adiados bigint[] := array[]::bigint[];
  v_resto_ids bigint[] := array[]::bigint[];
  v_resto_gk boolean[] := array[]::boolean[];
  v_out_ids bigint[] := array[]::bigint[];
  v_out_gk boolean[] := array[]::boolean[];
  v_out_time int[] := array[]::int[];
  v_n int := 0;
  v_gk_n int := 0;
  v_ultimo_gk int;
  v_ultimo int;
  v_early_n int;
  v_i int;
  v_j int;
  v_sorteio_id bigint;
  v_escolhido int;
  v_destino int;
  v_time int;
  v_no_time int[];
  v_tem_gk boolean[];
  v_candidatos int[];
  v_colocados int := 0;
  v_achou boolean;
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

  -- Goleiro a mais do que os times que vão jogar fica na espera.
  -- Sai quem chegou por último. Não se abre um time só para goleiro.
  loop
    v_n := coalesce(array_length(v_sel_ids, 1), 0);
    exit when v_n = 0;

    v_ultimo := least(v_times, ceil(v_n::numeric / v_por_time)::int);
    v_gk_n := 0;
    v_ultimo_gk := 0;

    for v_i in 1 .. v_n loop
      if v_sel_gk[v_i] then
        v_gk_n := v_gk_n + 1;
        v_ultimo_gk := v_i;
      end if;
    end loop;

    exit when v_gk_n <= v_ultimo;

    v_sel_ids := coalesce(v_sel_ids[1:v_ultimo_gk - 1], array[]::bigint[])
      || coalesce(v_sel_ids[v_ultimo_gk + 1:v_n], array[]::bigint[]);
    v_sel_gk := coalesce(v_sel_gk[1:v_ultimo_gk - 1], array[]::boolean[])
      || coalesce(v_sel_gk[v_ultimo_gk + 1:v_n], array[]::boolean[]);
  end loop;

  delete from sorteio where id is not null;

  insert into sorteio (created_at, num_times, jogadores_por_time)
  values (now(), v_times, v_por_time)
  returning id into v_sorteio_id;

  if v_n = 0 then
    return jsonb_build_object('ok', true, 'convocados', 0);
  end if;

  v_early_n := (v_ultimo - 1) * v_por_time;
  v_front_ids := coalesce(v_sel_ids[1:v_early_n], array[]::bigint[]);
  v_front_gk := coalesce(v_sel_gk[1:v_early_n], array[]::boolean[]);
  v_back_ids := coalesce(v_sel_ids[v_early_n + 1:v_n], array[]::bigint[]);
  v_back_gk := coalesce(v_sel_gk[v_early_n + 1:v_n], array[]::boolean[]);

  if coalesce(array_length(v_front_ids, 1), 0) > 0 then
    select
      coalesce(array_agg(pid order by ord), array[]::bigint[]),
      coalesce(array_agg(pgk order by ord), array[]::boolean[])
      into v_front_ids, v_front_gk
    from (
      select pid, pgk, random() as ord
      from unnest(v_front_ids, v_front_gk) as t(pid, pgk)
    ) s;
  end if;

  if coalesce(array_length(v_back_ids, 1), 0) > 0 then
    select
      coalesce(array_agg(pid order by ord), array[]::bigint[]),
      coalesce(array_agg(pgk order by ord), array[]::boolean[])
      into v_back_ids, v_back_gk
    from (
      select pid, pgk, random() as ord
      from unnest(v_back_ids, v_back_gk) as t(pid, pgk)
    ) s;
  end if;

  v_no_time := array_fill(0, array[v_times]);
  v_tem_gk := array_fill(false, array[v_times]);

  for v_i in 1 .. coalesce(array_length(v_front_ids, 1), 0) loop
    v_candidatos := array[]::int[];

    for v_time in 1 .. v_ultimo - 1 loop
      if v_no_time[v_time] >= v_por_time then
        continue;
      end if;
      if v_front_gk[v_i] and v_tem_gk[v_time] then
        continue;
      end if;
      v_candidatos := v_candidatos || v_time;
    end loop;

    if coalesce(array_length(v_candidatos, 1), 0) > 0 then
      v_escolhido := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
    elsif v_front_gk[v_i] then
      v_candidatos := array[]::int[];

      for v_time in 1 .. v_ultimo - 1 loop
        if not v_tem_gk[v_time] and v_no_time[v_time] > 0 then
          v_candidatos := v_candidatos || v_time;
        end if;
      end loop;

      if coalesce(array_length(v_candidatos, 1), 0) = 0 then
        v_adiados := array_append(v_adiados, v_front_ids[v_i]);
        continue;
      end if;

      v_escolhido := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
      v_candidatos := array[]::int[];

      for v_time in 1 .. v_ultimo - 1 loop
        if v_no_time[v_time] < v_por_time then
          v_candidatos := v_candidatos || v_time;
        end if;
      end loop;

      if coalesce(array_length(v_candidatos, 1), 0) = 0 then
        v_adiados := array_append(v_adiados, v_front_ids[v_i]);
        continue;
      end if;

      v_destino := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
      v_achou := false;

      for v_j in 1 .. coalesce(array_length(v_out_ids, 1), 0) loop
        if v_out_time[v_j] = v_escolhido and not v_out_gk[v_j] then
          v_out_time[v_j] := v_destino;
          v_achou := true;
          exit;
        end if;
      end loop;

      if not v_achou then
        v_adiados := array_append(v_adiados, v_front_ids[v_i]);
        continue;
      end if;

      v_no_time[v_escolhido] := v_no_time[v_escolhido] - 1;
      v_no_time[v_destino] := v_no_time[v_destino] + 1;
    else
      continue;
    end if;

    v_out_ids := array_append(v_out_ids, v_front_ids[v_i]);
    v_out_gk := array_append(v_out_gk, v_front_gk[v_i]);
    v_out_time := array_append(v_out_time, v_escolhido);
    v_no_time[v_escolhido] := v_no_time[v_escolhido] + 1;
    if v_front_gk[v_i] then
      v_tem_gk[v_escolhido] := true;
    end if;
  end loop;

  for v_i in 1 .. coalesce(array_length(v_back_ids, 1), 0) loop
    v_candidatos := array[]::int[];

    if not v_back_gk[v_i] then
      for v_time in 1 .. v_ultimo - 1 loop
        if v_no_time[v_time] < v_por_time then
          v_candidatos := v_candidatos || v_time;
        end if;
      end loop;
    end if;

    if coalesce(array_length(v_candidatos, 1), 0) > 0 then
      v_escolhido := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
      v_out_ids := array_append(v_out_ids, v_back_ids[v_i]);
      v_out_gk := array_append(v_out_gk, false);
      v_out_time := array_append(v_out_time, v_escolhido);
      v_no_time[v_escolhido] := v_no_time[v_escolhido] + 1;
    else
      v_resto_ids := array_append(v_resto_ids, v_back_ids[v_i]);
      v_resto_gk := array_append(v_resto_gk, v_back_gk[v_i]);
    end if;
  end loop;

  for v_i in 1 .. coalesce(array_length(v_adiados, 1), 0) loop
    exit when v_no_time[v_ultimo] >= v_por_time or v_tem_gk[v_ultimo];

    v_out_ids := array_append(v_out_ids, v_adiados[v_i]);
    v_out_gk := array_append(v_out_gk, true);
    v_out_time := array_append(v_out_time, v_ultimo);
    v_no_time[v_ultimo] := v_no_time[v_ultimo] + 1;
    v_tem_gk[v_ultimo] := true;
  end loop;

  for v_i in 1 .. coalesce(array_length(v_resto_ids, 1), 0) loop
    exit when v_no_time[v_ultimo] >= v_por_time;
    if v_resto_gk[v_i] and v_tem_gk[v_ultimo] then
      continue;
    end if;

    v_out_ids := array_append(v_out_ids, v_resto_ids[v_i]);
    v_out_gk := array_append(v_out_gk, v_resto_gk[v_i]);
    v_out_time := array_append(v_out_time, v_ultimo);
    v_no_time[v_ultimo] := v_no_time[v_ultimo] + 1;
    if v_resto_gk[v_i] then
      v_tem_gk[v_ultimo] := true;
    end if;
  end loop;

  v_no_time := array_fill(0, array[v_times]);

  for v_i in 1 .. coalesce(array_length(v_out_ids, 1), 0) loop
    v_time := v_out_time[v_i];
    v_no_time[v_time] := v_no_time[v_time] + 1;

    insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
    values (v_sorteio_id, v_out_ids[v_i], v_time, v_no_time[v_time]);

    v_colocados := v_colocados + 1;
  end loop;

  return jsonb_build_object('ok', true, 'convocados', v_colocados);
end;
$$;

revoke all on function public.completar_sorteio() from public, anon, authenticated;

notify pgrst, 'reload schema';
