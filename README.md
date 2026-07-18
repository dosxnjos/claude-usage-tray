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
  semanal de 7d) quando há dado fresco. Sem dado, a linha só diz o motivo
  (token expirado / API limitando) — **nunca um número cacheado**.
- **Ícone da bandeja**: um anel que mostra a janela de **sessão (5h)** da conta
  ativa (verde < 60% < âmbar < 85% < vermelho). É o número que responde "vou
  bater no limite agora?", sem precisar nem do hover.

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
**ligado**). Quando ligado, o app troca sozinho para outra conta assim que a
conta **ativa** trava — sem precisar abrir o popup e clicar.

Regra de decisão, a cada refresh (60s): calcula-se o instante em que cada conta
fica utilizável de novo —

- se a semana (**7d**) dela estiver em 100%, é o reset da 7d que manda (a conta
  segue travada mesmo que a sessão de 5h já tenha zerado);
- senão, se a sessão (**5h**) estiver em 100%, é o reset dela;
- senão, a conta já está utilizável agora.

Só dispara se a conta **ativa** estiver travada por essa conta. A troca vai
para a conta elegível com o **menor** desses instantes — em caso de empate, ou
se a própria ativa já for a "melhor", **não faz nada** (evita ficar
pingue-pongueando entre contas logo após um reset). Não há cooldown por tempo
entre trocas: a cada refresh (60s) a regra acima roda de novo do zero sobre o
dado mais fresco — é isso, sozinho, que evita a oscilação, sem precisar de um
temporizador extra que só atrapalharia a se recuperar de uma reversão (abaixo).

Um aviso (balão) surge quando a troca **não é confirmada** e some sozinho
quando a conta ativa volta a ficar utilizável; a tentativa se repete no
próximo refresh, sem diálogo modal. **Nunca usa `--force`**: forçar ativaria a
credencial guardada sem primeiro salvar o login vivo, e o refresh token é de
uso único — se ele tiver girado desde o último backup, o `--force` descarta a
versão nova e pode quebrar a conta.

**Risco conhecido:** já foi observado (não de forma reprodutível) o `cswap`
reportar sucesso na troca e, minutos depois, ela reverter sozinha — provável
efeito de alguma outra sessão do Claude Code (você costuma rodar várias ao
mesmo tempo) reescrevendo `~/.claude.json` com a própria identidade em cache.
O app não confia num sucesso passado: cada refresh reconfere do zero se a
conta ativa ainda está travada, então uma reversão silenciosa é detectada e
tentada de novo no ciclo seguinte (até 60s depois), sem precisar de você.

## De onde vêm os dados

Do **`cswap --list --json`**. O app roda esse comando a cada 60s num runspace de
fundo e desenha o resultado. Aproveitar o cswap (em vez de chamar a API direto)
traz três vantagens:

- **Refresha tokens sozinho.** Quando o token de uma conta inativa expira, o
  `cswap --list` renova e reescreve no disco — então a conta volta a mostrar
  dados sem você fazer nada. (Foi por isso que uma conta "morta" voltou depois de
  você rodar `cswap --list` no terminal: não foi coincidência.)
- **Não toma 429.** O cswap tem cache de 15s, que absorve as chamadas.
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
elas aparecem com dados. Se ainda assim uma conta não tiver dado fresco, a linha
mostra só o motivo (`token expirado`, `re-login preciso`, etc.) e encolhe — o app
**nunca inventa um número cacheado**. Nas linhas compactas aparecem só as duas
barras que importam de relance (sessão 5h e semanal 7d); o detalhe por modelo
(Fable) fica no card da conta ativa.

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
