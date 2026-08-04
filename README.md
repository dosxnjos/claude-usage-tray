# Claude Usage Tray

Medidor de uso do Claude / Claude Code na **bandeja do Windows**. Passe o mouse
sobre o ícone e o popup aparece; clique para fixá-lo.

É a resposta Windows ao [ClaudeUsageBar](https://www.claudeusagebar.com/), que é
só para macOS.

![ícone](claude-usage-tray.png)

## O que ele mostra

- **Conta ativa** em destaque: barras de uso da janela de **5h**, da semana de
  **7d** e — quando o plano mede Opus à parte — de **opus**, cada uma com o
  horário de reset e a contagem regressiva.
- **Demais contas** do `cswap`, cada uma com as **duas barras** (sessão de 5h e
  semanal de 7d) e o tempo pro reset de cada uma. Quando o dado é fresco, o canto
  direito diz `agora`. Quando o `cswap` não tem medição recente mas guardou a
  última útil (`lastGoodUsage`, cswap 0.24+), as barras aparecem **em cinza** com
  a idade no lugar do `agora` (`8h atras`). Sem nenhuma medição, a linha só diz o
  motivo (`re-login preciso`, `API limitando`…). O app **nunca mostra número
  velho sem dizer que é velho**.
- **Ícone da bandeja**: um anel que mostra a janela de **sessão (5h)** da conta
  ativa (verde < 60% < âmbar < 85% < vermelho). É o número que responde "vou
  bater no limite agora?", sem precisar nem do hover. Se o valor exibido for uma
  medição antiga, o anel fica **cinza** — a escala de cor só vale para dado vivo.
  **De 95% em diante o anel dá zoom na reta final:** a faixa 95→100 passa a
  ocupar a volta inteira (97% = dois quintos, 99% = quatro quintos) e um **ponto
  no centro** avisa que a escala mudou. Sem isso, 98% e 100% são o mesmo desenho
  num ícone de 16 pixels.

## O que dá pra fazer

Passe o mouse no ícone: o popup abre e **fica aberto** enquanto o cursor estiver
sobre ele. Clique no ícone para fixá-lo.

- **Trocar de conta:** clique na linha de qualquer conta inativa. Equivale a
  `cswap --switch-to N`.
- **Remover uma conta:** o `x` ao lado dela, sempre com confirmação. Equivale a
  `cswap remove N` — apaga a credencial guardada pelo `cswap`, **não** cancela o
  login na Anthropic.

As duas ações são recusadas pelo `cswap` enquanto houver **sessão Claude viva**
naquela conta; nesse caso o app mostra a mensagem dele, em vez de fingir sucesso.

## Auto-switch de conta

Liga/desliga em **Auto-switch de conta**, no menu do botão direito (padrão:
**ligado**). Desde 24/07/2026 a decisão e a troca são do **próprio cswap**
(motor `cswap auto`, introduzido no cswap 0.19+): com o toggle ligado, cada
refresh roda um tick `cswap auto --once --json` em segundo plano, antes de
buscar a lista — se houve troca, o popup e o anel já mostram a conta nova no
mesmo ciclo. O app só traduz os eventos do tick em balões; quem decide,
executa e guarda estado (cooldown, quarentena) é o cswap.

A política é a do cswap (defaults; ajuste com `cswap config set autoswitch.*`):

- **Proativa:** troca quando a janela vinculante da conta ativa — o pior entre
  **5h**, **7d** e, nesta máquina, o semanal do **Fable**
  (`autoswitch.model Fable`) — chega a **90%**, sem esperar cravar 100%.
  Trocando antes de travar, as sessões Claude vivas pegam a conta nova
  enquanto a antiga ainda vale.
- O alvo é a conta com **mais folga**; ela precisa estar abaixo do threshold e
  superar a ativa em **10 pontos** (histerese anti pingue-pongue). Entre
  trocas proativas há **cooldown de 5 min** — que deixa de valer quando a
  ativa crava 100% (aí qualquer conta com folga real serve, já).
- Antes de ativar o alvo, o cswap **renova o token** dele se estiver perto de
  expirar; refresh token morto põe a conta em **quarentena** (sai sozinha
  quando você re-loga nela). Se o uso da ativa ficar ilegível por 3 ticks
  seguidos, há **failover** para qualquer conta saudável.
- Conta com sessão `cswap run` viva nunca é alvo automático; `cswap disable N`
  segura uma conta fora da rotação sem deslogá-la.

Balões: **troca feita** (informativo, com origem → destino e o gatilho),
**conta em quarentena** (aviso, com o comando de recuperação) e **todas as
contas esgotadas** (aviso, uma vez por episódio, com o reset mais cedo). O
resto — abaixo do threshold, histerese não vencida, erro transitório — é
silêncio; o próximo refresh reavalia.

O risco antigo da troca "confirmada" que revertia sozinha morreu com a
delegação: o processo que decide é o mesmo que escreve, sob os locks do
cswap. A troca **manual** (clique na linha) continua conferindo o resultado
no `sequence.json`, como sempre — e continua sem `--force`, que descartaria
um refresh token fresco e poderia quebrar a conta.

## De onde vêm os dados

Do **`cswap --list --json`**. O app roda esse comando a cada 60s num runspace de
fundo e desenha o resultado. Aproveitar o cswap (em vez de chamar a API direto)
traz três vantagens:

- **Refresha tokens sozinho.** Quando o token de uma conta inativa expira, o
  `cswap --list` renova e reescreve no disco — então a conta volta a mostrar
  dados sem você fazer nada. (Foi por isso que uma conta "morta" voltou depois de
  você rodar `cswap --list` no terminal: não foi coincidência.)
- **Não toma 429.** O orçamento do endpoint de usage é **por access token**, não
  por processo — quem poller por fora não ganha dado, só divide (e derruba) o
  mesmo orçamento. O cswap concentra isso num store compartilhado por todas as
  superfícies dele (list/TUI/watch/auto), com cadência adaptativa e backoff de
  429; nós lemos o resultado. (Até a 0.19 isso era um cache simples de 15s.)
- **Traz o uso por modelo.** A linha **Fable** (e outros modelos com limite
  próprio) vem no campo `scoped[]` — que a API de usage crua não expõe pelos
  campos `five_hour`/`seven_day`.

Sem `cswap` instalado, o app cai para um modo simples: a única conta logada no
Claude Code, lida de `~/.claude/.credentials.json`, chamando a API direto (aí
sem refresh e sem Fable). Diferente do app de macOS, **nunca precisa do cookie de
sessão do claude.ai**.

O app continua **somente leitura de credenciais**: quem rotaciona/grava token é o
cswap, não nós.

## Contas inativas

O cswap renova o token da conta inativa ao listar, então na maioria das vezes
elas aparecem com dados. Se uma conta não tiver medição fresca, o app tenta a
última medição útil que o cswap guardou (`lastGoodUsage`) e a desenha **cinza,
com a idade ao lado**; só quando não existe nem isso a linha encolhe e mostra o
motivo (`token expirado`, `re-login preciso`, etc.). O que o app não faz é
**passar número velho por atual** — a idade anda sempre junto do número. Nas
linhas compactas aparecem só as duas barras que importam de relance (sessão 5h e
semanal 7d), cada uma com o tempo pro reset embaixo; o detalhe por modelo (Fable)
fica no card da conta ativa.

> **Requer cswap 0.24+.** O campo `lastGoodUsage` nasceu ali (release 0.24.0,
> PR #170). Com um cswap mais velho nada quebra: sem o campo, a conta simplesmente
> volta a mostrar só o motivo, como antes.

## Como funciona por dentro

O uso é buscado num **runspace de fundo** a cada 60s e mantido em memória, então
o hover só precisa desenhar — o popup nunca espera a rede. Um snapshot em
`%LOCALAPPDATA%\claude-usage-tray\snapshot.json` faz o primeiro hover depois de
um boot já pintar na hora.

O hover funciona porque a "zona quente" que mantém o popup aberto é a **união**
do popup com o retângulo do ícone (obtido via `Shell_NotifyIconGetRect`), mais
uma folga de ~220ms ao sair. Sem o retângulo do ícone, um cursor parado sobre ele
fecharia o popup, já que `MouseMove` para de disparar quando o mouse para.

## Uso

```powershell
# rodar direto
powershell -NoProfile -ExecutionPolicy Bypass -File .\claude-usage-tray.ps1

# gerar o .exe (requer: Install-Module ps2exe -Scope CurrentUser)
.\build.ps1
```

Menu do botão direito: **Refresh now**, **Start with Windows** (cria atalho na
pasta Startup), **Auto-switch de conta** (liga/desliga a troca automática,
padrão ligado), **Open Claude Switch** (se o `claude-switch-gui` estiver ao
lado) e **Exit**.

### Flags de diagnóstico

```powershell
# coleta uma vez, imprime o JSON e sai (para ver o que a API respondeu)
.\claude-usage-tray.ps1 -Once

# renderiza o popup e o anel em PNGs, sem precisar do ícone vivo
.\claude-usage-tray.ps1 -Preview .\out
```

## Antes de mexer no código

Leia [`CLAUDE.md`](CLAUDE.md). Ele lista os invariantes (token é só leitura; o
hover nunca espera a rede; cache expira com a janela) e as **armadilhas do
PowerShell 5.1** que fazem código correto falhar aqui — `@()` sobre
`List[object]`, PSCustomObject virando `null` ao cruzar runspace,
`ConvertFrom-Json` que não desenrola array, e exceção em handler do WinForms
virando caixa de diálogo de crash.
