import { createClient } from "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm";
import { supabaseAnonKey, supabaseUrl } from "./config.js";

const avisoConfig = document.querySelector("#aviso-config");
const formLogin = document.querySelector("#form-login");
const campoUsuario = document.querySelector("#usuario");
const campoSenha = document.querySelector("#senha");
const loginMsg = document.querySelector("#login-msg");
const painel = document.querySelector("#painel-admin");
const estadoLocal = document.querySelector("#estado-local");
const formAdmin = document.querySelector("#form-admin");
const campoRaio = document.querySelector("#raio");
const campoTimes = document.querySelector("#num-times");
const campoPorTime = document.querySelector("#por-time");
const botaoDefinirLocal = document.querySelector("#definir-local");
const adminMsg = document.querySelector("#admin-msg");
const confirmaNovo = document.querySelector("#confirma-novo");
const botaoNovo = document.querySelector("#novo-jogo");

let supabase = null;
let sessao = null;

function configurado() {
  return Boolean(
    supabaseUrl &&
    supabaseAnonKey &&
    !supabaseUrl.includes("SEU-PROJETO") &&
    !supabaseAnonKey.includes("SUA-CHAVE-ANON")
  );
}

function mensagemErro(codigo) {
  switch (codigo) {
    case "gps_impreciso":
      return "O GPS está impreciso. Espere um pouco, em lugar aberto, e tente de novo.";
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
    default:
      return "Não foi possível concluir. Tente de novo.";
  }
}

function textoFalhaGps(erro) {
  const codigo = erro && erro.code;
  if (codigo === 1) return "Permita a localização para marcar o campo.";
  if (codigo === 3) return "A localização demorou demais. Tente de novo ao ar livre.";
  if (codigo === 0) return "Este celular não informou a localização.";
  return "Não foi possível ler a localização. Abra o link no Chrome ou no Safari.";
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

function inteiro(input) {
  const valor = Number(input.value);
  return Number.isInteger(valor) ? valor : Number.NaN;
}

function lerFormulario() {
  return {
    p_raio_m: inteiro(campoRaio),
    p_num_times: inteiro(campoTimes),
    p_jogadores_por_time: inteiro(campoPorTime),
  };
}

async function carregarParametros() {
  const { data, error } = await supabase.rpc("ler_parametros");
  if (error) throw error;
  const parametros = primeiraLinha(data);
  if (!parametros) return;
  const ativo = document.activeElement;
  if (![campoRaio, campoTimes, campoPorTime].includes(ativo)) {
    campoRaio.value = parametros.raio_m;
    campoTimes.value = parametros.num_times;
    campoPorTime.value = parametros.jogadores_por_time;
  }
  estadoLocal.textContent = parametros.campo_definido
    ? "O local do campo já está salvo."
    : "O local do campo ainda não foi marcado. Faça isso no centro do campo.";
}

async function entrar(evento) {
  evento.preventDefault();
  if (!supabase) {
    loginMsg.textContent = "Ligue o banco em config.js antes de entrar.";
    return;
  }
  const botao = formLogin.querySelector("button[type=submit]");
  botao.disabled = true;
  loginMsg.textContent = "Conferindo…";
  try {
    const { data, error } = await supabase.rpc("entrar_admin", {
      p_usuario: campoUsuario.value,
      p_senha: campoSenha.value,
    });
    if (error) throw error;
    if (!data || !data.ok) {
      loginMsg.textContent = mensagemErro(data && data.erro);
      return;
    }
    sessao = { usuario: campoUsuario.value, senha: campoSenha.value };
    formLogin.hidden = true;
    painel.hidden = false;
    await carregarParametros();
  } catch (erro) {
    const texto = `${erro && erro.message ? erro.message : ""} ${erro && erro.details ? erro.details : ""}`;
    loginMsg.textContent = /entrar_admin|schema cache|PGRST202/i.test(texto)
      ? "O banco ainda está na versão anterior. Rode supabase/atualizar-admin.sql no SQL Editor do Supabase."
      : "Não foi possível entrar.";
    console.error(erro);
  } finally {
    botao.disabled = false;
  }
}

async function salvarParametros(atualizarLocalDoCampo) {
  if (!supabase || !sessao) return;
  const campos = lerFormulario();
  if (![campos.p_raio_m, campos.p_num_times, campos.p_jogadores_por_time].every(Number.isInteger)) {
    adminMsg.textContent = "Preencha raio, times e jogadores com números inteiros.";
    return;
  }
  adminMsg.textContent = atualizarLocalDoCampo ? "Lendo a localização do campo…" : "Salvando…";
  let lat = null;
  let lng = null;
  let precisao = null;

  if (atualizarLocalDoCampo) {
    try {
      const posicao = await lerGps();
      lat = posicao.coords.latitude;
      lng = posicao.coords.longitude;
      precisao = posicao.coords.accuracy;
    } catch (erro) {
      adminMsg.textContent = textoFalhaGps(erro);
      return;
    }
  }

  const { data, error } = await supabase.rpc("salvar_parametros", {
    p_usuario: sessao.usuario,
    p_senha: sessao.senha,
    ...campos,
    p_lat: lat,
    p_lng: lng,
    p_precisao: precisao,
    p_atualizar_local: atualizarLocalDoCampo,
  });

  if (error) {
    adminMsg.textContent = "Não foi possível salvar.";
    console.error(error);
    return;
  }
  if (!data || !data.ok) {
    adminMsg.textContent = data && data.erro === "gps_impreciso" && atualizarLocalDoCampo
      ? "O GPS está impreciso para marcar o campo. Tente de novo ao ar livre."
      : mensagemErro(data && data.erro);
    return;
  }

  adminMsg.textContent = atualizarLocalDoCampo ? "Local do campo salvo." : "Parâmetros salvos.";
  await carregarParametros();
}

async function apagarJogo() {
  if (!supabase || !sessao) return;
  botaoNovo.disabled = true;
  const { data, error } = await supabase.rpc("novo_jogo", {
    p_usuario: sessao.usuario,
    p_senha: sessao.senha,
  });
  botaoNovo.disabled = false;
  if (error) {
    adminMsg.textContent = "Não foi possível começar um jogo novo.";
    return;
  }
  if (!data || !data.ok) {
    adminMsg.textContent = mensagemErro(data && data.erro);
    return;
  }
  confirmaNovo.hidden = true;
  adminMsg.textContent = "Lista e sorteio apagados. O local do campo continua salvo.";
}

function iniciar() {
  if (!configurado()) {
    avisoConfig.hidden = false;
    avisoConfig.textContent = "Falta ligar o banco. Coloque a URL e a chave anon do Supabase em config.js. Os passos estão no arquivo COMO-USAR.md.";
    return;
  }
  supabase = createClient(supabaseUrl, supabaseAnonKey);
}

formLogin.addEventListener("submit", entrar);
formAdmin.addEventListener("submit", (evento) => {
  evento.preventDefault();
  salvarParametros(false);
});
botaoDefinirLocal.addEventListener("click", () => salvarParametros(true));
botaoNovo.addEventListener("click", () => {
  confirmaNovo.hidden = false;
});
document.querySelector("#novo-sim").addEventListener("click", apagarJogo);
document.querySelector("#novo-nao").addEventListener("click", () => {
  confirmaNovo.hidden = true;
});

iniciar();
