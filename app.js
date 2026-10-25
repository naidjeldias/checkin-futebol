import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { supabaseAnonKey, supabaseUrl } from "./config.js";

// Horário mostrado na lista. Troque só esta linha se o grupo for de outro fuso.
const FUSO = "America/Sao_Paulo";
const CHAVE_NOME = "checkin-futebol-nome";
const CHAVE_APARELHO = "checkin-futebol-aparelho";

const statusTexto = document.querySelector("#status-texto");
const tentarLocal = document.querySelector("#tentar-local");
const avisoConfig = document.querySelector("#aviso-config");
const formCheckin = document.querySelector("#form-checkin");
const campoNome = document.querySelector("#nome");
const campoGoleiro = document.querySelector("#goleiro");
const resultado = document.querySelector("#resultado");
const jaNaLista = document.querySelector("#ja-na-lista");
const jaNaListaTexto = document.querySelector("#ja-na-lista-texto");
const botaoSair = document.querySelector("#sair-lista");
const lista = document.querySelector("#lista");
const listaVazia = document.querySelector("#lista-vazia");
const contagem = document.querySelector("#contagem");
const regraSorteio = document.querySelector("#regra-sorteio");
const botaoSugerir = document.querySelector("#sugerir");
const confirmaSorteio = document.querySelector("#confirma-sorteio");
const sorteioAviso = document.querySelector("#sorteio-aviso");
const timesEl = document.querySelector("#times");
const esperaEl = document.querySelector("#espera");

const estado = {
  parametros: null,
  checkins: [],
  sorteio: null,
  atribuicoes: [],
};

let supabase = null;
let carregando = false;
let cargaPendente = false;
let jaCarregou = false;
let presenca = null;
let bancoDesatualizado = false;

function configurado() {
  return Boolean(
    supabaseUrl &&
    supabaseAnonKey &&
    !supabaseUrl.includes("SEU-PROJETO") &&
    !supabaseAnonKey.includes("SUA-CHAVE-ANON")
  );
}

function el(tag, classe, texto) {
  const node = document.createElement(tag);
  if (classe) node.className = classe;
  if (texto != null) node.textContent = texto;
  return node;
}

function formatarDistancia(metros) {
  const valor = Number(metros) || 0;
  if (valor < 1000) return `${valor} m`;
  return `${(valor / 1000).toFixed(1).replace(".", ",")} km`;
}

function hora(iso) {
  return new Date(iso).toLocaleTimeString("pt-BR", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone: FUSO,
  });
}

function normalizar(nome) {
  return nome
    .trim()
    .replace(/\s+/g, " ")
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{M}/gu, "");
}

function aparelhoId() {
  try {
    const guardado = localStorage.getItem(CHAVE_APARELHO) || "";
    if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(guardado)) {
      return guardado;
    }
    if (!crypto.randomUUID) return "";
    const novo = crypto.randomUUID();
    localStorage.setItem(CHAVE_APARELHO, novo);
    return novo;
  } catch (erro) {
    return "";
  }
}

function bancoAntigo(erro) {
  const texto = `${erro && erro.message ? erro.message : ""} ${erro && erro.details ? erro.details : ""} ${erro && erro.code ? erro.code : ""}`;
  return /schema cache|PGRST202|Could not find the function/i.test(texto);
}

function marcarBancoDesatualizado() {
  bancoDesatualizado = true;
  formCheckin.hidden = true;
  tentarLocal.hidden = true;
  jaNaLista.hidden = true;
  statusTexto.textContent = "O banco ainda está na versão anterior. Rode supabase/atualizar-aparelho.sql no SQL Editor do Supabase.";
}

function mostrarPresenca(data, recemChegou) {
  presenca = { nome: data.nome, posicao: data.posicao };
  formCheckin.hidden = true;
  tentarLocal.hidden = true;
  jaNaLista.hidden = false;
  jaNaListaTexto.textContent = recemChegou
    ? `Você é o ${data.posicao}º.`
    : `Este celular já colocou ${data.nome} na lista. Você é o ${data.posicao}º.`;
  statusTexto.textContent = "Você está na lista.";
  localStorage.setItem(CHAVE_NOME, data.nome);
  campoNome.value = data.nome;
}

function mensagemErro(codigo) {
  switch (codigo) {
    case "gps_impreciso":
      return "O GPS está impreciso. Espere um pouco, em lugar aberto, e tente de novo.";
    case "campo_indefinido":
      return "O campo ainda não foi definido. Quem organiza marca o local na página de administrador.";
    case "nome_invalido":
      return "Use um nome com 2 a 40 letras.";
    case "aparelho_invalido":
      return "Não foi possível identificar este celular. Abra o link no Chrome ou no Safari.";
    case "credenciais_invalidas":
    case "senha_incorreta":
      return "Usuário ou senha incorretos.";
    case "raio_invalido":
      return "O raio precisa estar entre 10 e 2000 metros.";
    case "times_invalidos":
      return "O número de times precisa estar entre 2 e 10.";
    case "jogadores_invalidos":
      return "Jogadores por time precisa estar entre 1 e 15.";
    case "local_invalido":
      return "Não foi possível ler a localização.";
    case "sem_parametros":
      return "Os parâmetros do jogo ainda não foram gravados.";
    default:
      return "Não foi possível concluir. Tente de novo.";
  }
}

function textoLonge(data) {
  return `Você está a ${formatarDistancia(data.distancia_m)} do campo. O limite é ${formatarDistancia(data.raio_m)}.`;
}

function dicaNavegador() {
  const ua = navigator.userAgent || "";
  if (/WhatsApp|Instagram|FBAN|FBAV/i.test(ua)) {
    return " Abra este link no Chrome ou no Safari: a localização costuma falhar dentro do WhatsApp.";
  }
  return " Se o pedido não aparecer, abra o link no Chrome ou no Safari.";
}

function textoFalhaGps(erro) {
  const codigo = erro && erro.code;
  if (codigo === 1) {
    return `Permita a localização para entrar na lista.${dicaNavegador()}`;
  }
  if (codigo === 3) {
    return `A localização demorou demais.${dicaNavegador()}`;
  }
  if (codigo === 0) {
    return "Este celular não informou a localização.";
  }
  return `Não foi possível ler a localização.${dicaNavegador()}`;
}

function lerGps() {
  return new Promise((resolve, reject) => {
    if (!navigator.geolocation) {
      reject({ code: 0 });
      return;
    }
    navigator.geolocation.getCurrentPosition(resolve, reject, {
      enableHighAccuracy: true,
      timeout: 15000,
      maximumAge: 0,
    });
  });
}

function primeiraLinha(data) {
  if (Array.isArray(data)) return data[0] || null;
  return data || null;
}

function aplicarRespostaLocal(data) {
  if (bancoDesatualizado) return;
  if (presenca) {
    mostrarPresenca(presenca, false);
    return;
  }

  tentarLocal.hidden = false;
  if (data.ok) {
    statusTexto.textContent = "Você está no campo. Coloque seu nome na lista.";
    formCheckin.hidden = false;
    tentarLocal.hidden = true;
    if (!campoNome.value) {
      campoNome.value = localStorage.getItem(CHAVE_NOME) || "";
    }
    return;
  }

  formCheckin.hidden = true;
  if (data.erro === "longe") {
    statusTexto.textContent = textoLonge(data);
    return;
  }
  statusTexto.textContent = mensagemErro(data.erro);
}

function render() {
  const pessoas = estado.checkins;
  const parametros = estado.parametros;

  lista.replaceChildren();
  pessoas.forEach((pessoa, indice) => {
    const item = el("li");
    const guardado = localStorage.getItem(CHAVE_NOME);
    if (guardado && normalizar(guardado) === normalizar(pessoa.nome)) {
      item.classList.add("eu");
    }
    item.append(el("span", "posicao", String(indice + 1)));
    const nome = el("span", "pessoa", pessoa.nome);
    if (pessoa.goleiro) nome.append(document.createTextNode(" "), el("span", "badge", "Goleiro"));
    item.append(nome, el("span", "hora", hora(pessoa.created_at)));
    lista.append(item);
  });

  listaVazia.hidden = pessoas.length > 0;
  contagem.textContent = pessoas.length === 1 ? "1 pessoa" : `${pessoas.length} pessoas`;

  if (parametros) {
    regraSorteio.textContent = `${parametros.num_times} times, ${parametros.jogadores_por_time} jogadores por time. Os dois primeiros times saem completos; o restante se divide por igual. Quem chegou antes entra. Depois do sorteio, quem chegar entra nas vagas que sobrarem, com as mesmas regras.`;
  }

  timesEl.replaceChildren();
  esperaEl.replaceChildren();
  sorteioAviso.hidden = true;

  if (!estado.sorteio) return;

  const sorteio = estado.sorteio;
  const parametrosMudaram = Boolean(
    parametros &&
    (sorteio.num_times !== parametros.num_times ||
      sorteio.jogadores_por_time !== parametros.jogadores_por_time)
  );
  if (parametrosMudaram) {
    sorteioAviso.hidden = false;
    sorteioAviso.textContent = "Os parâmetros mudaram. Sorteie de novo para usar os novos números.";
  }

  const porId = new Map(pessoas.map((pessoa) => [String(pessoa.id), pessoa]));
  const presentes = new Set();
  const tamanhoPrimeira = { 1: 0, 2: 0 };
  let goleirosPrimeira = 0;

  for (let time = 1; time <= sorteio.num_times; time += 1) {
    const card = el("article", "time");
    card.append(el("h3", null, `Time ${time}`));
    const nomes = el("ul", "nomes");
    const membros = estado.atribuicoes
      .filter((item) => item.time_num === time)
      .sort((a, b) => {
        const goleiroA = porId.get(a.checkin_id)?.goleiro ? 0 : 1;
        const goleiroB = porId.get(b.checkin_id)?.goleiro ? 0 : 1;
        if (goleiroA !== goleiroB) return goleiroA - goleiroB;
        return a.posicao - b.posicao;
      });

    membros.forEach((item) => {
      const pessoa = porId.get(String(item.checkin_id));
      if (!pessoa) return;
      presentes.add(String(pessoa.id));
      if (time <= 2) {
        tamanhoPrimeira[time] += 1;
        if (pessoa.goleiro) goleirosPrimeira += 1;
      }
      const linha = el("li");
      linha.append(el("span", "pessoa", pessoa.nome));
      if (pessoa.goleiro) linha.append(el("span", "badge", "Goleiro"));
      nomes.append(linha);
    });

    const vazias = sorteio.jogadores_por_time - membros.length;
    for (let vaga = 0; vaga < vazias; vaga += 1) {
      nomes.append(el("li", "vaga", "vaga"));
    }

    card.append(nomes);
    timesEl.append(card);
  }

  const faltaVaga = (time) =>
    time <= sorteio.num_times && tamanhoPrimeira[time] < sorteio.jogadores_por_time;
  if (
    !parametrosMudaram &&
    presentes.size > 0 &&
    goleirosPrimeira < 2 &&
    (faltaVaga(1) || faltaVaga(2))
  ) {
    sorteioAviso.hidden = false;
    sorteioAviso.textContent = "Sem dois goleiros na primeira partida: cada time sem goleiro fica com uma vaga para puxar alguém de fora.";
  }

  const espera = pessoas.filter((pessoa) => !presentes.has(String(pessoa.id)));
  if (espera.length === 0) return;

  const bloco = el("div", "espera");
  bloco.append(el("h3", null, "Espera"));
  const nomes = el("ul", "nomes");
  espera.forEach((pessoa) => {
    const linha = el("li");
    linha.append(el("span", "posicao", String(pessoas.indexOf(pessoa) + 1)));
    const nome = el("span", "pessoa", pessoa.nome);
    if (pessoa.goleiro) nome.append(document.createTextNode(" "), el("span", "badge", "Goleiro"));
    linha.append(nome);
    nomes.append(linha);
  });
  bloco.append(nomes);
  esperaEl.append(bloco);
}

async function carregar() {
  if (!supabase) return;
  if (carregando) {
    cargaPendente = true;
    return;
  }
  carregando = true;
  try {
    const [parametrosRes, checkinsRes, sorteioRes, atribuicoesRes] = await Promise.all([
      supabase.rpc("ler_parametros"),
      supabase
        .from("checkins")
        .select("id, nome, goleiro, created_at")
        .order("created_at", { ascending: true })
        .order("id", { ascending: true }),
      supabase
        .from("sorteio")
        .select("id, created_at, num_times, jogadores_por_time")
        .order("created_at", { ascending: false })
        .limit(1),
      supabase.from("sorteio_jogadores").select("sorteio_id, checkin_id, time_num, posicao"),
    ]);

    const erro = parametrosRes.error || checkinsRes.error || sorteioRes.error || atribuicoesRes.error;
    if (erro) throw erro;

    estado.parametros = primeiraLinha(parametrosRes.data);
    estado.checkins = checkinsRes.data || [];
    estado.sorteio = (sorteioRes.data || [])[0] || null;
    const sorteioId = estado.sorteio && estado.sorteio.id;
    estado.atribuicoes = (atribuicoesRes.data || []).filter(
      (item) => String(item.sorteio_id) === String(sorteioId)
    );
    jaCarregou = true;
    render();
  } catch (erro) {
    if (!jaCarregou) {
      statusTexto.textContent = "Não foi possível carregar a lista. Confira a conexão e o config.js.";
    }
    console.error(erro);
  } finally {
    carregando = false;
    if (cargaPendente) {
      cargaPendente = false;
      carregar();
    }
  }
}

function agendarCarga() {
  carregar();
}

async function atualizarLocal() {
  if (bancoDesatualizado || presenca) return;
  statusTexto.textContent = "Buscando a localização…";
  tentarLocal.hidden = true;
  try {
    const posicao = await lerGps();
    const { data, error } = await supabase.rpc("verificar_local", {
      p_lat: posicao.coords.latitude,
      p_lng: posicao.coords.longitude,
      p_precisao: posicao.coords.accuracy,
    });
    if (error) throw error;
    aplicarRespostaLocal(data);
  } catch (erro) {
    if (presenca || bancoDesatualizado) return;
    formCheckin.hidden = true;
    tentarLocal.hidden = false;
    if (erro && erro.message && !erro.code) {
      statusTexto.textContent = "Não foi possível confirmar se você está no campo.";
      return;
    }
    statusTexto.textContent = textoFalhaGps(erro);
  }
}

async function enviarCheckin(evento) {
  evento.preventDefault();
  const botao = formCheckin.querySelector("button[type=submit]");
  const aparelho = aparelhoId();
  botao.disabled = true;
  resultado.textContent = "Confirmando a localização…";
  if (!aparelho) {
    resultado.textContent = mensagemErro("aparelho_invalido");
    botao.disabled = false;
    return;
  }
  try {
    const posicao = await lerGps();
    const { data, error } = await supabase.rpc("checkin", {
      p_nome: campoNome.value,
      p_lat: posicao.coords.latitude,
      p_lng: posicao.coords.longitude,
      p_precisao: posicao.coords.accuracy,
      p_goleiro: campoGoleiro.checked,
      p_aparelho: aparelho,
    });
    if (error) throw error;
    campoGoleiro.checked = false;
    if (!data || !data.ok) {
      if (data && data.erro === "aparelho_ja_usou") {
        mostrarPresenca(data, false);
        resultado.textContent = "";
        await carregar();
        return;
      }
      if (data && (data.erro === "nome_invalido" || data.erro === "aparelho_invalido")) {
        resultado.textContent = mensagemErro(data.erro);
        return;
      }
      if (!data) {
        resultado.textContent = "Não foi possível entrar na lista.";
        return;
      }
      resultado.textContent = "";
      aplicarRespostaLocal(data);
      return;
    }
    if (data.ja_existia) {
      const meu = await supabase.rpc("meu_checkin", { p_aparelho: aparelho });
      if (meu.error) throw meu.error;
      if (meu.data && meu.data.ok) {
        mostrarPresenca(meu.data, false);
        resultado.textContent = "";
      } else {
        localStorage.setItem(CHAVE_NOME, data.nome);
        campoNome.value = data.nome;
        resultado.textContent = `Você já está na lista. Você é o ${data.posicao}º.`;
      }
      await carregar();
      return;
    }
    mostrarPresenca(data, true);
    resultado.textContent = "";
    await carregar();
  } catch (erro) {
    if (bancoAntigo(erro)) {
      marcarBancoDesatualizado();
      return;
    }
    resultado.textContent = erro && erro.code
      ? textoFalhaGps(erro)
      : "Não foi possível entrar na lista.";
  } finally {
    botao.disabled = false;
  }
}

async function sincronizarAparelho() {
  const aparelho = aparelhoId();
  if (!aparelho) return;
  try {
    const { data, error } = await supabase.rpc("meu_checkin", { p_aparelho: aparelho });
    if (error) throw error;
    if (data && data.ok) {
      mostrarPresenca(data, false);
      render();
    }
  } catch (erro) {
    if (bancoAntigo(erro)) marcarBancoDesatualizado();
    console.error(erro);
  }
}

async function sairDaLista() {
  const aparelho = aparelhoId();
  botaoSair.disabled = true;
  if (!aparelho) {
    jaNaListaTexto.textContent = mensagemErro("aparelho_invalido");
    botaoSair.disabled = false;
    return;
  }
  try {
    const { data, error } = await supabase.rpc("sair_da_lista", { p_aparelho: aparelho });
    if (error) throw error;
    if (!data || !data.ok) {
      jaNaListaTexto.textContent = mensagemErro(data && data.erro);
      return;
    }
    presenca = null;
    jaNaLista.hidden = true;
    resultado.textContent = "";
    await carregar();
    await atualizarLocal();
  } catch (erro) {
    if (bancoAntigo(erro)) {
      marcarBancoDesatualizado();
      return;
    }
    jaNaListaTexto.textContent = "Não foi possível sair da lista.";
    console.error(erro);
  } finally {
    botaoSair.disabled = false;
  }
}

async function sortear() {
  if (!supabase) return;
  botaoSugerir.disabled = true;
  confirmaSorteio.hidden = true;
  try {
    const { data, error } = await supabase.rpc("sugerir_times");
    if (error) throw error;
    if (!data || !data.ok) {
      sorteioAviso.hidden = false;
      sorteioAviso.textContent = mensagemErro(data && data.erro);
      return;
    }
    await carregar();
  } catch (erro) {
    sorteioAviso.hidden = false;
    sorteioAviso.textContent = "Não foi possível sortear os times.";
    console.error(erro);
  } finally {
    botaoSugerir.disabled = false;
  }
}

function iniciar() {
  if (!configurado()) {
    avisoConfig.hidden = false;
    avisoConfig.textContent = "Falta ligar o banco. Coloque a URL e a chave anon do Supabase em config.js. Os passos estão no arquivo COMO-USAR.md.";
    statusTexto.textContent = "A lista aparece aqui depois que o banco estiver ligado.";
    botaoSugerir.disabled = true;
    return;
  }

  supabase = createClient(supabaseUrl, supabaseAnonKey);
  carregar();
  sincronizarAparelho().then(() => {
    if (!presenca && !bancoDesatualizado) atualizarLocal();
  });

  supabase
    .channel("checkin-ao-vivo")
    .on("postgres_changes", { event: "*", schema: "public", table: "checkins" }, agendarCarga)
    .on("postgres_changes", { event: "*", schema: "public", table: "sorteio" }, agendarCarga)
    .on("postgres_changes", { event: "*", schema: "public", table: "sorteio_jogadores" }, agendarCarga)
    .subscribe();

  setInterval(() => {
    if (!document.hidden) carregar();
  }, 8000);
}

tentarLocal.addEventListener("click", atualizarLocal);
formCheckin.addEventListener("submit", enviarCheckin);
botaoSair.addEventListener("click", sairDaLista);
botaoSugerir.addEventListener("click", () => {
  if (estado.sorteio) {
    confirmaSorteio.hidden = false;
    return;
  }
  sortear();
});
document.querySelector("#confirma-sim").addEventListener("click", sortear);
document.querySelector("#confirma-nao").addEventListener("click", () => {
  confirmaSorteio.hidden = true;
});

iniciar();
