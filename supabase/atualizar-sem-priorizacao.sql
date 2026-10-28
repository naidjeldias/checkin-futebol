-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- Cada time fica com no máximo um goleiro.
-- Os times 1 e 2 saem completos, mesmo sem goleiro. O restante se divide por igual.

-- Depois do sorteio, coloca quem ainda não tem time nas vagas que sobrarem.
-- Quem já está num time não muda. Os times 1 e 2 completam antes dos demais.
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
  v_menor int;
  v_candidatos int[];
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
    v_candidatos := array[]::int[];
    v_menor := null;

    for v_i in 1 .. least(2, v_times) loop
      if v_no_time[v_i] >= v_por_time then
        continue;
      end if;
      if v_fila.goleiro and v_tem_gk[v_i] then
        continue;
      end if;

      if v_menor is null or v_no_time[v_i] < v_menor then
        v_menor := v_no_time[v_i];
        v_candidatos := array[v_i];
      elsif v_no_time[v_i] = v_menor then
        v_candidatos := v_candidatos || v_i;
      end if;
    end loop;

    if coalesce(array_length(v_candidatos, 1), 0) = 0 then
      v_menor := null;

      for v_i in 3 .. v_times loop
        if v_no_time[v_i] >= v_por_time then
          continue;
        end if;
        if v_fila.goleiro and v_tem_gk[v_i] then
          continue;
        end if;

        if v_menor is null or v_no_time[v_i] < v_menor then
          v_menor := v_no_time[v_i];
          v_candidatos := array[v_i];
        elsif v_no_time[v_i] = v_menor then
          v_candidatos := v_candidatos || v_i;
        end if;
      end loop;
    end if;

    if coalesce(array_length(v_candidatos, 1), 0) = 0 then
      continue;
    end if;

    v_time := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];

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

-- Sorteia quem chegou antes. Os times 1 e 2 saem completos, mesmo sem goleiro.
-- Cada time fica com no máximo um goleiro. O restante se divide por igual.
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
  v_gk_restantes int := 0;
  v_i int;
  v_j int;
  v_k int;
  v_sorteio_id bigint;
  v_proximo int;
  v_escolhido int;
  v_time int;
  v_menor int;
  v_casas int;
  v_pode boolean;
  v_no_time int[];
  v_tem_gk boolean[];
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

  select
    coalesce(array_agg(pid order by ord), array[]::bigint[]),
    coalesce(array_agg(pgk order by ord), array[]::boolean[])
    into v_ids, v_gks
  from (
    select pid, pgk, random() as ord
    from unnest(v_sel_ids, v_sel_gk) as t(pid, pgk)
  ) s;
  v_sel_ids := v_ids;
  v_sel_gk := v_gks;

  delete from sorteio where id is not null;

  insert into sorteio (created_at, num_times, jogadores_por_time)
  values (now(), v_times, v_por_time)
  returning id into v_sorteio_id;

  v_no_time := array_fill(0, array[greatest(v_times, 1)]);
  v_tem_gk := array_fill(false, array[greatest(v_times, 1)]);
  v_proximo := 1 + floor(random() * least(v_times, 2))::int;
  v_gk_restantes := v_gk_n;

  for v_i in 1 .. coalesce(array_length(v_sel_ids, 1), 0) loop
    v_escolhido := null;

    if v_times >= 2 then
      for v_j in 1 .. 2 loop
        if v_j = 1 then
          v_time := v_proximo;
        else
          v_time := 3 - v_proximo;
        end if;

        v_pode := true;
        if v_no_time[v_time] >= v_por_time then
          v_pode := false;
        elsif v_sel_gk[v_i] and v_tem_gk[v_time] then
          v_pode := false;
        elsif not v_sel_gk[v_i]
           and not v_tem_gk[v_time]
           and v_no_time[v_time] + 1 >= v_por_time then
          -- Segura o último lugar enquanto ainda há goleiro convocado sem time.
          v_casas := 0;
          for v_k in 1 .. v_times loop
            if v_k <> v_time
               and not v_tem_gk[v_k]
               and v_no_time[v_k] < v_por_time then
              v_casas := v_casas + 1;
            end if;
          end loop;
          if v_gk_restantes > v_casas then
            v_pode := false;
          end if;
        end if;

        if v_pode then
          v_escolhido := v_time;
          exit;
        end if;
      end loop;
    end if;

    if v_escolhido is null then
      v_menor := null;
      v_candidatos := array[]::int[];

      for v_time in 3 .. v_times loop
        if v_no_time[v_time] >= v_por_time then
          continue;
        end if;
        if v_sel_gk[v_i] and v_tem_gk[v_time] then
          continue;
        end if;
        if not v_sel_gk[v_i]
           and not v_tem_gk[v_time]
           and v_no_time[v_time] + 1 >= v_por_time then
          v_casas := 0;
          for v_k in 1 .. v_times loop
            if v_k <> v_time
               and not v_tem_gk[v_k]
               and v_no_time[v_k] < v_por_time then
              v_casas := v_casas + 1;
            end if;
          end loop;
          if v_gk_restantes > v_casas then
            continue;
          end if;
        end if;

        if v_menor is null or v_no_time[v_time] < v_menor then
          v_menor := v_no_time[v_time];
          v_candidatos := array[v_time];
        elsif v_no_time[v_time] = v_menor then
          v_candidatos := v_candidatos || v_time;
        end if;
      end loop;

      if coalesce(array_length(v_candidatos, 1), 0) = 0 then
        continue;
      end if;

      v_escolhido := v_candidatos[1 + floor(random() * array_length(v_candidatos, 1))::int];
    end if;

    v_no_time[v_escolhido] := v_no_time[v_escolhido] + 1;
    if v_sel_gk[v_i] then
      v_tem_gk[v_escolhido] := true;
      v_gk_restantes := v_gk_restantes - 1;
    end if;

    insert into sorteio_jogadores (sorteio_id, checkin_id, time_num, posicao)
    values (v_sorteio_id, v_sel_ids[v_i], v_escolhido, v_no_time[v_escolhido]);

    if v_escolhido <= 2 then
      v_proximo := 3 - v_escolhido;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'convocados', coalesce(array_length(v_sel_ids, 1), 0)
  );
end;
$$;

revoke all on function public.completar_sorteio() from public, anon, authenticated;

select public.completar_sorteio();

notify pgrst, 'reload schema';
