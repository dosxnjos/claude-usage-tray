# Plano — delegar o auto-switch ao `cswap auto` (upgrade 0.23) + recompilar (2026-07-24)

## Entendimento do pedido

O Gabriel pediu: "melhore o meu fluxo e execute e compile". Contexto da conversa:
o cswap ganhou um motor de auto-switch nativo (`cswap auto`, módulo
`autoswitch.py`) que faz tudo que o `Invoke-AutoSwitch` do tray faz e mais
(proativo a 90%, histerese de 10 pts, cooldown 5 min com escape at-limit,
freshening de token do alvo, quarentena de refresh token morto, failover quando
o usage da ativa fica ilegível, polling adaptativo). A instalada é 0.19.0; a
0.23.0 saiu em 23/07 e traz ainda `consume-first`, preservação de OAuth de MCP
na troca (0.22) e fix de deadlock 429 multi-máquina.

Escopo: (1) upgrade do cswap para 0.23.0; (2) o tray passa a **delegar** a
decisão/execução do auto-switch ao `cswap auto --once`, mantendo só a exibição
(balões) e o toggle; (3) docs atualizadas (CLAUDE.md, README); (4) recompilar o
exe e relançar; (5) memória `reference_cswap_internals` corrigida; (6) diário.

Fora do escopo: mudar visual do popup/ícone; mexer na troca manual (clique na
linha) e na remoção; adotar `consume-first` (fica na estratégia default `best`
— trocar de estratégia é decisão de uso, um comando à parte, documentado).

## O que NÃO muda (guardrails)

- **Hover nunca espera rede** (invariante nº4): o tick `cswap auto --once` roda
  DENTRO do runspace de fundo do Collect, nunca na UI thread. (Hoje o
  `Invoke-AutoSwitch` roda na UI thread via Complete-Refresh — a delegação
  MELHORA isso; não regredir.)
- **Sem cache por conta / popup mostra só o último fetch** (nº5) e snapshot só
  para pintar o boot.
- **`.ps1` ASCII puro** (nº8): strings novas de balão sem acento, glifos via
  `[char]0xNNNN`.
- **Ícone = janela 5h da ativa** (nº6); linhas compactas com 5h+7d (nº7).
- **Troca manual e remoção** continuam como estão (`Invoke-Cswap --switch-to N`
  / `remove`), com as regras de confirmação via `sequence.json`
  (`Get-ActiveAccountNum`) intactas.
- **Nunca `--force`** (nº9) — o `cswap auto` também não força; a regra segue.
- **Balão, nunca MessageBox** em caminho de timer (nº11).
- Guard de instância única, mutex, DPI, tudo do WinForms: intocado.
- `-Preview` intocado. `-Once` continua read-only (NÃO roda o tick de auto).

## Abordagem / arquitetura

**Por que delegar:** manter duas engines de decisão (tray + cswap) é conflito
armado — o cswap agora persiste estado (`autoswitch_state.json`) com file lock
e política muito mais completa. O tray vira "frontend": liga/desliga, executa o
tick, mostra o que aconteceu. A fraqueza documentada do fluxo antigo (o
`"switched": true` sem persistir, armadilha de ambiente nº4) morre junto: quem
decide E executa é o mesmo processo cswap, sob os locks dele.

**Como fica o ciclo de refresh (60s, com backoff 429 até 10 min):**

1. Runspace de fundo (`$script:Collect`, agora com `param($autoTick)`):
   - se `$autoTick` (toggle ligado): roda `cswap auto --once --json` (JSONL de
     eventos no stdout; exit 0=trocou, 1=erro, 2=nada, 3=bloqueado). Timeout
     45s (freshen/escalação podem ir à rede).
   - depois roda `cswap --list --json` como hoje. Ordem importa: se o tick
     trocou de conta, a lista já volta com a ativa nova — o popup e o anel
     refletem a troca no MESMO ciclo, sem re-fetch extra.
   - devolve UMA string JSON envelope: `{"accounts":[...],"auto":{"exit":N,
     "events":[...]}}` (`auto` = `$null` quando toggle off ou cswap ausente).
2. `Complete-Refresh` (UI thread): parseia o envelope
   (`ConvertFrom-CollectJson` atualizado), atualiza `$script:data` com
   `accounts` como hoje, e chama `Show-AutoSwitchEvents $auto` (novo, substitui
   `Invoke-AutoSwitch`):
   - evento `switch` (e `dryRun` false) → balão Info "Conta trocada
     automaticamente: #A -> #B (email) [gatilho]". Reseta
     `$script:autoSwitchWarned`.
   - evento `account-quarantined` → balão Warning com a dica de recuperação
     (raro e importante; o engine só emite na transição, não spamma).
   - evento `all-exhausted` → balão Warning UMA vez por episódio
     (`$script:autoSwitchWarned`), com o reset mais cedo se houver.
   - exit 2 (nada a fazer) → reseta `$script:autoSwitchWarned`.
   - exit 1 / `no-qualifying-candidate` / demais → silêncio (transitório;
     próximo refresh reavalia). Sem MessageBox nunca.
3. Funções mortas removidas: `Get-UsableAt`, `Get-AutoSwitchTarget`,
   `Invoke-AutoSwitch` (e os comentários-monólito acima delas). O comentário do
   cabeçalho do Collect ganha a explicação da delegação.

**Política de decisão passa a ser a do cswap** (settings dele, não do tray):
threshold 90%, histerese 10 pts, cooldown 300s (só proativo; at-limit fura),
`unhealthyTicks` 3. Ajustes via `cswap config set autoswitch.*`. Vamos setar
`autoswitch.model Fable`: o limite semanal por-modelo do Fable passa a contar
na janela vinculante — é o limite que morde primeiro no uso real do Gabriel
(sessões Fable o dia todo). Reverter: `cswap config set autoswitch.model ""`.

**Alternativas descartadas:**
- *Rodar `cswap auto` em loop como subprocess persistente* — mais um processo
  pra babysittar (morre? relança? logs?); o `--once` por refresh é exatamente o
  modo cron-friendly que o engine documenta, e o estado persistido
  (cooldown/quarentena) já vive no cswap.
- *Manter a decisão no tray e só usar o cswap pra executar* — joga fora
  freshening/quarentena/failover e mantém a corrida de duas engines.
- *Tick na UI thread (como o Invoke-AutoSwitch antigo)* — bloquearia o hover
  por segundos; no runspace de fundo custa zero.

## Decisões e trade-offs

- **Proativo a 90% substitui o reativo a 100%.** O fluxo que o Gabriel
  descreveu (esperar 100%) era o comportamento antigo; o proativo troca ANTES
  de travar, que é estritamente melhor pro uso dele (sessões vivas pegam a
  conta nova sem engasgo). Custo: pode trocar "sem precisar" se o uso recua —
  mitigado pela histerese de 10 pts e cooldown do próprio cswap.
- **Cooldown de 5 min volta a existir (o do cswap).** O invariante nº12 do tray
  ("não reintroduza cooldown") era sobre um cooldown CEGO do tray por cima da
  própria decisão; o do cswap é da engine dona da decisão, com escape at-limit,
  e o cenário que o nº12 protegia (reversão silenciosa) morre com a delegação.
  O invariante será reescrito, não violado às escondidas.
- **`--once` a cada refresh** (60s normal, até 10 min sob 429): cadência igual
  à do engine em loop (interval 60). Sob backoff do tray o auto também
  desacelera — aceitável, é justamente quando a API está limitando.
- **`autoswitch.model Fable`**: se alguma conta não reportar janela Fable, o
  engine emite `config-warning` e segue nos 5h/7d pra ela — degrada suave.
- Upgrade 0.19→0.23 muda o formato humano do `cswap list`, mas o tray só
  consome `--json`, cujo contrato é aditivo (promessa documentada no engine:
  "consumers must ignore unknown fields"). Risco residual coberto pelo teste
  `-Once` pós-upgrade.

## Passos

1. [x] **Upgrade cswap**: `uv tool upgrade claude-swap`; conferir
   `cswap --version` = 0.23.0. Validar: `cswap --list --json` parseia e traz
   `accounts` com `usage.fiveHour/sevenDay/scoped`; `cswap auto --once
   --dry-run --json` emite eventos JSONL e exit code coerente. Pronto quando os
   três comandos rodam limpos.
2. [x] **Config**: `cswap config set autoswitch.model Fable` (checar antes no
   `--list --json` que a janela scoped "Fable" existe nas contas; se o comando
   de config tiver outra sintaxe na 0.23, `cswap config --help` decide). Pronto
   quando `cswap config get autoswitch.model` (ou equivalente) devolve Fable.
3. [x] **Editar `claude-usage-tray.ps1`** (edições cirúrgicas via patch/Edit):
   a. `$script:Collect`: adicionar `param([bool]$autoTick)` no topo; nova
      função interna `Invoke-CswapAutoOnce` (clone do `Invoke-CswapJson` com
      `Arguments='auto --once --json'`, timeout 45000, parseia stdout linha a
      linha em eventos; devolve `@{ exit=<code>; events=<ArrayList> }` ou
      `$null` se cswap ausente); rodar ANTES do `Invoke-CswapJson` da lista;
      devolver envelope `[pscustomobject]@{ accounts=<como hoje>; auto=$auto }
      | ConvertTo-Json -Depth 8 -Compress` (inclusive no caminho fallback
      sem cswap, com `auto=$null`).
   b. `ConvertFrom-CollectJson`: parsear o envelope; devolver
      `[pscustomobject]@{ Accounts=,$list; Auto=$parsed.auto }` mantendo o walk
      manual do array (traps nº3 do PS 5.1). Ajustar TODOS os consumidores:
      `Complete-Refresh` (usa `.Accounts`/`.Auto`) e o bloco `-Once` (imprime o
      envelope re-serializado).
   c. `Complete-Refresh`: trocar `try { Invoke-AutoSwitch } catch {}` por
      `try { Show-AutoSwitchEvents $parsed.Auto } catch {}`.
   d. Novo `Show-AutoSwitchEvents($auto)` no lugar dos antigos: regras de balão
      da seção Abordagem (switch → Info + reset warned; account-quarantined →
      Warning; all-exhausted → Warning 1x/episódio; exit 2 → reset warned;
      resto silencioso). Strings ASCII.
   e. Remover `Get-UsableAt`, `Get-AutoSwitchTarget`, `Invoke-AutoSwitch` e
      seus blocos de comentário; atualizar o comentário-cabeçalho do Collect e
      o comentário do state `$script:autoSwitchWarned`.
   f. `Start-Refresh`: `[void]$ps.AddScript($script:Collect).AddArgument(
      [bool]$script:autoSwitchEnabled)` (uma linha; o resto igual).
   Pronto quando: parser do PowerShell não acusa erro e não sobra referência
   aos símbolos removidos (`Select-String 'Get-AutoSwitchTarget|Get-UsableAt|
   Invoke-AutoSwitch'` vazio).
4. [x] **Testar sem UI**: sintaxe via
   `[System.Management.Automation.Language.Parser]::ParseFile` (no powershell
   5.1); depois `powershell -NoProfile -File .\claude-usage-tray.ps1 -Once` →
   JSON com as contas (auto = null no -Once, por design). Pronto quando o JSON
   sai íntegro com as contas reais.
5. [x] **Docs**: reescrever no `CLAUDE.md` os invariantes 9–12 (delegação:
   tray não decide; --force segue banido no manual; balão-não-modal mantém;
   nº12 vira nota histórica) e a armadilha de ambiente nº4 (nota: mitigada pela
   delegação); reescrever `README.md` § "Auto-switch de conta" (política do
   cswap: 90%/histerese/cooldown/quarentena/failover, como ajustar via `cswap
   config`, o que cada balão significa). Pronto quando não sobra texto
   descrevendo a decisão antiga como atual.
6. [x] **Compilar e relançar**: `Get-Process 'Claude Usage Tray' |
   Stop-Process -Force` (armadilha nº2: instância pendurada engole o launch);
   `./build.ps1`; relançar com `Start-Process '.\Claude Usage Tray.exe'`;
   conferir processo vivo após ~5s. NUNCA testar via powershell-oculto-de-
   powershell (armadilha Defender nº1). Pronto quando o processo novo está de
   pé com o ícone na bandeja.
7. [x] **Memória**: atualizar `reference_cswap_internals.md` (0.23: `--json`
   existe, engine `cswap auto`, autoswitch_state.json, polling adaptativo
   0.20+, MCP OAuth preservado 0.22) — a versão atual afirma "sem flag --json",
   hoje falso. Ajustar a linha no MEMORY.md se a descrição mudar.
8. [x] **Diário** (`cerebro/diario/2026-07-24.md`) via skill consolidar +
   atualizar hub do projeto se existir.

## Riscos / o que pode dar errado

- **`cswap config` pode ter sintaxe diferente na 0.23** (set/get) — resolver
  com `--help` na hora; não chutar.
- **`uv tool upgrade` pode quebrar o shim `cswap.exe`** no PATH (precedente:
  release notes 0.23 citam reinstalls quebrando o menubar do macOS) — validar
  `cswap --version` logo após.
- **Timeout do tick**: freshen + escalação em rede lenta pode passar de 45s →
  o runner mata o processo e devolve `$null`; o refresh seguinte tenta de
  novo. Sem retry imediato (mesma filosofia do resto do app).
- **ps2exe ausente/desatualizado** na máquina → `Install-Module ps2exe -Scope
  CurrentUser` se o build reclamar.
- **Exe em uso** trava o build → matar o processo antes (passo 6 já cobre).
- **Balão de quarentena em loop**: o engine só emite o evento na transição
  (estado persistido), então não deve repetir; se na prática repetir (bug
  upstream), degradar para 1x/episódio com o mesmo flag — anotar em ARMADILHAS.

> Auditado em 2026-09-01 (overhaul): FECHADO — cswap auto --once --json em claude-usage-tray.ps1 (l.292/336/916); md nunca commitado (?? no git)
