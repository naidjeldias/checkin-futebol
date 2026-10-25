-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- Depois do sorteio, quem chegar entra nas vagas que sobrarem.
-- Quem já está num time não muda de lugar.

-- Depois do sorteio, coloca quem ainda não tem time nas vagas que sobrarem.
-- Quem já está num time não muda. Time 1 ou 2 sem goleiro guarda uma vaga.
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
  v_gk_n int := 0;
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
      v_gk_n := v_gk_n + 1;
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

    if v_fila.goleiro then
      if v_gk_n < v_times then
        for v_i in 1 .. least(2, v_times) loop
          if not v_tem_gk[v_i] and v_no_time[v_i] < v_por_time then
            v_candidatos := v_candidatos || v_i;
          end if;
        end loop;

        if coalesce(array_length(v_candidatos, 1), 0) = 0 then
          for v_i in 3 .. v_times loop
            if not v_tem_gk[v_i] and v_no_time[v_i] < v_por_time then
              v_candidatos := v_candidatos || v_i;
            end if;
          end loop;
        end if;
      end if;
    else
      v_menor := null;

      for v_i in 1 .. least(2, v_times) loop
        if v_tem_gk[v_i] then
          if v_no_time[v_i] >= v_por_time then
            continue;
          end if;
        elsif v_no_time[v_i] >= v_por_time - 1 then
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

          if v_menor is null or v_no_time[v_i] < v_menor then
            v_menor := v_no_time[v_i];
            v_candidatos := array[v_i];
          elsif v_no_time[v_i] = v_menor then
            v_candidatos := v_candidatos || v_i;
          end if;
        end loop;
      end if;
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
      v_gk_n := v_gk_n + 1;
    end if;
    v_colocados := v_colocados + 1;
  end loop;

  return jsonb_build_object('ok', true, 'colocados', v_colocados);
end;
$$;

create or replace function public.checkin(
  p_nome text,
  p_lat double precision,
  p_lng double precision,
  p_precisao double precision,
  p_goleiro boolean,
  p_aparelho uuid
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
  v_exist_id bigint;
  v_exist_nome text;
  v_aparelho_do_nome uuid;
  v_link_id bigint;
  v_link_nome text;
begin
  if p_aparelho is null then
    return jsonb_build_object('ok', false, 'erro', 'aparelho_invalido');
  end if;

  v_nome := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');

  if char_length(v_nome) < 2
     or char_length(v_nome) > 40
     or v_nome !~ '[[:alpha:]]' then
    return jsonb_build_object('ok', false, 'erro', 'nome_invalido');
  end if;

  v_norm := nome_normalizado(v_nome);

  select c.id, c.nome, a.aparelho
    into v_exist_id, v_exist_nome, v_aparelho_do_nome
  from checkins c
  left join checkin_aparelho a on a.checkin_id = c.id
  where c.nome_norm = v_norm;

  select a.checkin_id, c.nome
    into v_link_id, v_link_nome
  from checkin_aparelho a
  join checkins c on c.id = a.checkin_id
  where a.aparelho = p_aparelho;

  if v_exist_id is not null then
    if v_aparelho_do_nome is null and v_link_id is null then
      insert into checkin_aparelho (aparelho, checkin_id)
      values (p_aparelho, v_exist_id)
      on conflict do nothing;
    end if;

    return jsonb_build_object(
      'ok', true,
      'ja_existia', true,
      'posicao', posicao_de(v_exist_id),
      'nome', v_exist_nome
    );
  end if;

  if v_link_id is not null then
    return jsonb_build_object(
      'ok', false,
      'erro', 'aparelho_ja_usou',
      'posicao', posicao_de(v_link_id),
      'nome', v_link_nome
    );
  end if;

  v_local := avaliar_local(p_lat, p_lng, p_precisao);
  if not (v_local ->> 'ok')::boolean then
    return v_local;
  end if;

  insert into checkins (nome, nome_norm, goleiro)
  values (v_nome, v_norm, coalesce(p_goleiro, false))
  returning id into v_id;

  insert into checkin_aparelho (aparelho, checkin_id)
  values (p_aparelho, v_id);

  perform completar_sorteio();

  return jsonb_build_object(
    'ok', true,
    'ja_existia', false,
    'posicao', posicao_de(v_id),
    'nome', v_nome
  );
exception
  when unique_violation then
    select c.id, c.nome, a.aparelho
      into v_exist_id, v_exist_nome, v_aparelho_do_nome
    from checkins c
    left join checkin_aparelho a on a.checkin_id = c.id
    where c.nome_norm = v_norm;

    if v_exist_id is not null then
      select a.checkin_id
        into v_link_id
      from checkin_aparelho a
      where a.aparelho = p_aparelho;

      if v_aparelho_do_nome is null and v_link_id is null then
        insert into checkin_aparelho (aparelho, checkin_id)
        values (p_aparelho, v_exist_id)
        on conflict do nothing;
      end if;

      return jsonb_build_object(
        'ok', true,
        'ja_existia', true,
        'posicao', posicao_de(v_exist_id),
        'nome', v_exist_nome
      );
    end if;

    select a.checkin_id, c.nome
      into v_link_id, v_link_nome
    from checkin_aparelho a
    join checkins c on c.id = a.checkin_id
    where a.aparelho = p_aparelho;

    if v_link_id is not null then
      return jsonb_build_object(
        'ok', false,
        'erro', 'aparelho_ja_usou',
        'posicao', posicao_de(v_link_id),
        'nome', v_link_nome
      );
    end if;

    raise;
end;
$$;

create or replace function public.sair_da_lista(p_aparelho uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id bigint;
begin
  if p_aparelho is null then
    return jsonb_build_object('ok', false, 'erro', 'aparelho_invalido');
  end if;

  select checkin_id into v_id
  from checkin_aparelho
  where aparelho = p_aparelho;

  if v_id is null then
    return jsonb_build_object('ok', true, 'ja_saiu', true);
  end if;

  delete from checkins where id = v_id;

  perform completar_sorteio();

  return jsonb_build_object('ok', true, 'ja_saiu', false);
end;
$$;

revoke all on function public.completar_sorteio() from public, anon, authenticated;

select public.completar_sorteio();

notify pgrst, 'reload schema';
