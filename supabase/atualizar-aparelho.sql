-- Rode isto uma vez se o banco já foi criado.
-- Cada celular passa a colocar um nome por jogo.
-- Novo jogo apaga a lista e libera o celular de novo.

create table if not exists checkin_aparelho (
  aparelho uuid primary key,
  checkin_id bigint not null unique references checkins (id) on delete cascade
);

drop function if exists public.checkin(text, double precision, double precision, double precision, boolean);

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

create or replace function public.meu_checkin(p_aparelho uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_id bigint;
  v_nome text;
begin
  if p_aparelho is null then
    return jsonb_build_object('ok', false, 'erro', 'aparelho_invalido');
  end if;

  select c.id, c.nome
    into v_id, v_nome
  from checkin_aparelho a
  join checkins c on c.id = a.checkin_id
  where a.aparelho = p_aparelho;

  if v_id is null then
    return jsonb_build_object('ok', false, 'erro', 'sem_checkin');
  end if;

  return jsonb_build_object(
    'ok', true,
    'nome', v_nome,
    'posicao', posicao_de(v_id)
  );
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

  return jsonb_build_object('ok', true, 'ja_saiu', false);
end;
$$;


revoke all on function public.checkin(text, double precision, double precision, double precision, boolean, uuid) from public;
revoke all on function public.meu_checkin(uuid) from public;
revoke all on function public.sair_da_lista(uuid) from public;

grant execute on function public.checkin(text, double precision, double precision, double precision, boolean, uuid) to anon, authenticated;
grant execute on function public.meu_checkin(uuid) to anon, authenticated;
grant execute on function public.sair_da_lista(uuid) to anon, authenticated;

revoke all on table public.checkin_aparelho from public, anon, authenticated;
alter table public.checkin_aparelho enable row level security;

notify pgrst, 'reload schema';
