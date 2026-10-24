# Como publicar o check-in

A página fica pronta no celular depois destes passos. O usuário e a senha do administrador ficam no banco. Eles não entram no `config.js`.

## 1. Criar o banco

1. Crie um projeto gratuito em [supabase.com](https://supabase.com).
2. Abra o SQL Editor e cole o arquivo `supabase/setup.sql`.
3. O acesso inicial é usuário `admin` e senha `admin`. Troque os dois no insert, se quiser, antes de rodar.
4. Rode a consulta uma vez.

Se o banco já foi criado com a versão anterior, rode `supabase/atualizar-admin.sql` em vez de repetir o setup. Isso passa o acesso para `admin` / `admin` e os padrões para 4 times de 6 jogadores.

Se o banco já existe, rode também `supabase/atualizar-sorteio.sql` uma vez. O sorteio passa a completar os times 1 e 2 antes de dividir o restante.

A lista mostra o horário de Brasília. Se o grupo for de outro fuso, troque a constante `FUSO` em `app.js`.

## 2. Ligar a página

1. No Supabase, abra Project Settings → API.
2. Copie a Project URL e a chave **anon** (também chamada de publishable). Não use a chave `service_role`.
3. Cole as duas em `config.js`.

## 3. Publicar o link

1. Crie um repositório no GitHub e envie esta pasta.
2. Em Settings → Pages, publique o branch `main` na pasta raiz (`/`).
3. O link fica parecido com `https://seu-usuario.github.io/checkin-futebol/`.
4. Mande esse link no grupo.

A chave anon no `config.js` é pública de propósito. Quem tem o link vê a lista de nomes. Mudar o campo, o raio, os times e apagar o jogo exigem o usuário e a senha na página de administrador.

## 4. No campo, uma vez

1. Abra o link no Chrome ou no Safari.
2. Toque em **Administrador**.
3. Entre com o usuário e a senha. O padrão é `admin` e `admin`.
4. Informe o raio em metros, o número de times e os jogadores por time. O padrão é 4 times de 6.
5. No centro do campo, com o GPS preciso, toque em **Definir este local como o campo**.
6. **Salvar parâmetros** muda raio, times e jogadores sem mexer no local.

O raio inicial é 200 metros. O check-in só abre depois que o local está salvo.

## No dia do jogo

- Quem está dentro do raio escreve o nome e toca em **Cheguei**.
- **Sou goleiro** começa desmarcado. Só marca quem for goleiro.
- A lista fica em ordem de chegada e pode ser vista por quem ainda está a caminho.
- **Sugerir times** sorteia os times e grava o resultado para todo mundo ver o mesmo sorteio.
- Entram primeiro quem chegou antes, até preencher `times × jogadores por time`.
- Cada time fica com no máximo um goleiro. Goleiro que passar disso fica na espera, e a próxima pessoa de linha sobe.
- Os times 1 e 2, que se enfrentam primeiro, saem completos. O restante se divide por igual entre os outros times.
- Sem goleiro nesse time, a última vaga fica aberta para puxar alguém de fora. Com um goleiro só, um time fica com essa vaga. Sem nenhum goleiro, os dois ficam com uma vaga.
- Se a lista lotar e essas vagas ficarem reservadas, quem chegou por último fica na espera.
- Sortear de novo pede confirmação e substitui o sorteio.
- **Novo jogo**, na página de administrador, apaga a lista e o sorteio. O local do campo continua salvo.

Se a localização não funcionar dentro do WhatsApp, abra o link no Chrome ou no Safari. O GPS precisa estar preciso (melhor que 100 m), de preferência ao ar livre.
