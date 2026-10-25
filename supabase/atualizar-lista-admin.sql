-- Rode este arquivo uma vez no SQL Editor do Supabase.
-- O administrador inclui e remove pessoas sem GPS e sem prender um celular.

create or replace function public.adicionar_pessoa(
  p_usuario text,
  p_senha text,
  p_nome text,
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
  v_id bigint;
begin
  if not credenciais_conferem(p_usuario, p_senha) then
    return jsonb_build_object('ok', false, 'erro', 'credenciais_invalidas');
  end if;

  v_nome := regexp_replace(trim(coalesce(p_nome, '')), '\s+', ' ', 'g');

  if char_length(v_nome) < 2
     or char_length(v_nome) > 40
     or v_nome !~ '[[:alpha:]]' then
    return jsonb_build_object('ok', false, 'erro', 'nome_invalido');
  end if;

  v_norm := nome_normalizado(v_nome);

  if exists (select 1 from checkins where nome_norm = v_norm) then
    return jsonb_build_object('ok', false, 'erro', 'nome_ja_existe');
  end if;

  insert into checkins (nome, nome_norm, goleiro)
  values (v_nome, v_norm, coalesce(p_goleiro, false))
  returning id into v_id;

  perform completar_sorteio();

  return jsonb_build_object(
    'ok', true,
    'posicao', posicao_de(v_id),
    'nome', v_nome
  );
exception
  when unique_violation then
    return jsonb_build_object('ok', false, 'erro', 'nome_ja_existe');
end;
$$;

create or replace function public.remover_pessoa(
  p_usuario text,
  p_senha text,
  p_id bigint
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

  if p_id is null then
    return jsonb_build_object('ok', true, 'ja_saiu', true);
  end if;

  delete from checkins where id = p_id;

  if not found then
    return jsonb_build_object('ok', true, 'ja_saiu', true);
  end if;

  perform completar_sorteio();

  return jsonb_build_object('ok', true, 'ja_saiu', false);
end;
$$;

revoke all on function public.adicionar_pessoa(text, text, text, boolean) from public;
revoke all on function public.remover_pessoa(text, text, bigint) from public;

grant execute on function public.adicionar_pessoa(text, text, text, boolean) to anon, authenticated;
grant execute on function public.remover_pessoa(text, text, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
