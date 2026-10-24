-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- O banco recusa apagar a lista inteira sem um filtro. Estas funções passam a usar um filtro.

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
  v_gk_ids bigint[] := array[]::bigint[];
  v_linha_ids bigint[] := array[]::bigint[];
  v_gk_embaralhado bigint[];
  v_linha_embaralhada bigint[];
  v_gk_count int;
  v_linha_count int;
  v_gk_nos_demais int;
  v_slots_linha int;
  v_linha_usar int;
  v_abertura_alvo int;
  v_abertura_usar int;
  v_resto_usar int;
  v_time int;
  v_menor int;
  v_no_time int[];
  v_ordem int[];
  v_candidatos int[];
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

  for v_i in 1 .. coalesce(array_length(v_sel_ids, 1), 0) loop
    if v_sel_gk[v_i] then
      v_gk_ids := array_append(v_gk_ids, v_sel_ids[v_i]);
    else
      v_linha_ids := array_append(v_linha_ids, v_sel_ids[v_i]);
    end if;
  end loop;

  v_gk_count := coalesce(array_length(v_gk_ids, 1), 0);
  v_linha_count := coalesce(array_length(v_linha_ids, 1), 0);
  v_gk_nos_demais := greatest(v_gk_count - 2, 0);
  v_abertura_alvo := 2 * greatest(v_por_time - 1, 0);
  v_slots_linha := v_abertura_alvo
    + greatest(v_times - 2, 0) * v_por_time
    - v_gk_nos_demais;
  v_linha_usar := least(v_linha_count, greatest(v_slots_linha, 0));

  if v_linha_usar = 0 then
    v_linha_ids := array[]::bigint[];
  else
    v_linha_ids := v_linha_ids[1:v_linha_usar];
  end if;

  select coalesce(array_agg(id order by random()), array[]::bigint[])
    into v_gk_embaralhado
  from unnest(v_gk_ids) as id;
  v_gk_ids := v_gk_embaralhado;

  select coalesce(array_agg(id order by random()), array[]::bigint[])
    into v_linha_embaralhada
  from unnest(v_linha_ids) as id;
  v_linha_ids := v_linha_embaralhada;

  v_abertura_usar := least(coalesce(array_length(v_linha_ids, 1), 0), v_abertura_alvo);
  v_resto_usar := coalesce(array_length(v_linha_ids, 1), 0) - v_abertura_usar;

  delete from sorteio where id is not null;

  insert into sorteio (created_at, num_times, jogadores_por_time)
  values (now(), v_times, v_por_time)
  returning id into v_sorteio_id;

  v_no_time := array_fill(0, array[greatest(v_times, 1)]);

  if v_gk_count > 0 and v_times >= 1 then
    select coalesce(array_agg(t order by random()), array[]::int[])
      into v_ordem
    from generate_series(1, least(v_times, 2)) as t;

    for v_i in 1 .. least(v_gk_count, coalesce(array_length(v_ordem, 1), 0)) loop
      v_time := v_ordem[v_i];
      v_no_time[v_time] := v_no_time[v_time] + 1;
      insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
      values (v_sorteio_id, v_gk_ids[v_i], v_time, v_no_time[v_time]);
    end loop;
  end if;

  if v_gk_count > 2 and v_times > 2 then
    select coalesce(array_agg(t order by random()), array[]::int[])
      into v_ordem
    from generate_series(3, v_times) as t;

    for v_i in 1 .. least(v_gk_count - 2, coalesce(array_length(v_ordem, 1), 0)) loop
      v_time := v_ordem[v_i];
      v_no_time[v_time] := v_no_time[v_time] + 1;
      insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
      values (v_sorteio_id, v_gk_ids[v_i + 2], v_time, v_no_time[v_time]);
    end loop;
  end if;

  if v_times >= 2 and v_abertura_usar > 0 then
    v_time := 1 + floor(random() * 2)::int;

    for v_i in 1 .. v_abertura_usar loop
      v_no_time[v_time] := v_no_time[v_time] + 1;
      insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
      values (v_sorteio_id, v_linha_ids[v_i], v_time, v_no_time[v_time]);

      v_time := 3 - v_time;
    end loop;
  end if;

  for v_i in 1 .. v_resto_usar loop
    v_menor := null;
    v_candidatos := array[]::int[];

    for v_time in 3 .. v_times loop
      if v_no_time[v_time] >= v_por_time then
        continue;
      end if;

      if v_menor is null or v_no_time[v_time] < v_menor then
        v_menor := v_no_time[v_time];
        v_candidatos := array[v_time];
      elsif v_no_time[v_time] = v_menor then
        v_candidatos := v_candidatos || v_time;
      end if;
    end loop;

    exit when coalesce(array_length(v_candidatos, 1), 0) = 0;

    v_time := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
    v_no_time[v_time] := v_no_time[v_time] + 1;
    insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
    values (v_sorteio_id, v_linha_ids[v_abertura_usar + v_i], v_time, v_no_time[v_time]);
  end loop;

  return jsonb_build_object(
    'ok', true,
    'convocados', coalesce(array_length(v_sel_ids, 1), 0),
    'goleiros', v_gk_count
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

  delete from sorteio_jogadores where checkin_id is not null;
  delete from checkins where id is not null;
  delete from sorteio where id is not null;

  return jsonb_build_object('ok', true);
end;
$$;
