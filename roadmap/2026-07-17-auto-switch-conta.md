# Auto-switch de conta no claude-usage-tray

**Data:** 2026-07-17 · **Autor do roadmap:** Fable (arquitetura) · **Executor:** agente Sonnet
**Status:** EXECUTADO em 2026-07-17 (F1-F5 completas). Ver
`C:\Dev\consolidado\claude-usage-tray\CONSOLIDADO-2026-07-17.md` para o
resumo final; pendência real: observar uma troca automática de ponta a ponta
na próxima vez que a conta ativa travar de verdade (não forçada neste
roadmap, por ser mutação real de estado).

## O pedido (nas palavras dele)

> "quero só um switch automático no app pra conta que vai resetar o limite de 5h
> primeiro (isso se o limite de 7 dias não estiver 100%; se estiver 100%, deve
> ser considerado pra essa conta o próprio limite de 7 dias)"

Contexto: o Gabriel alterna entre 2 contas Anthropic com `cswap`. Quando a conta
ativa atinge o session limit (5h), hoje ele troca manualmente. O app de bandeja
(`claude-usage-tray.ps1`, PowerShell 5.1 + WinForms, empacotado com ps2exe) já
coleta o uso das duas contas a cada 60s — a troca automática fecha o ciclo.

⚠️ **Antes de tocar no código, leia `CLAUDE.md` deste projeto inteiro.** Ele
lista invariantes e armadilhas do PS 5.1 verificadas na marra (runspace que
anula PSCustomObject, `@()` sobre `List[object]`, handlers WinForms que viram
crash modal, `.ps1` ASCII puro etc.). Este roadmap não as repete — mas todas
se aplicam.

## Estado atual (investigado em 17/07/2026)

- **Coleta:** `$script:Collect` roda `cswap --list --json` num runspace de fundo
  a cada 60s (`$BASE_REFRESH_MS`, backoff até 10min em 429) e devolve string
  JSON; `ConvertFrom-CollectJson` reconstrói. Resultado em `$script:data`:
  lista de contas com `Num`, `Email`, `Active`, `Status` e `Bars[]`, cada barra
  `{ Label; Pct; ResetsAt }`. Labels relevantes: `'5h'` e `'7d'` (as `scoped`
  por modelo, ex. Fable, existem mas ficam fora desta feature). `ResetsAt` é
  string ISO — `Format-ResetClock`/`Format-ResetRel` já a parseiam com
  `[datetimeoffset]::Parse`.
- **Ponto de decisão natural:** `Complete-Refresh` — é onde `$script:data`
  acaba de ser atualizado com dados frescos.
- **Troca manual já existe:** `Switch-Account` → `Invoke-Cswap @('--switch-to', N)`,
  e confirma o resultado lendo `sequence.json` (`Get-ActiveAccountNum`) porque
  **exit code do cswap não prova nada** (invariante nº 3 do CLAUDE.md).
- **Config/estado em disco:** `$script:stateDir` = `%LOCALAPPDATA%\claude-usage-tray`
  (hoje só `snapshot.json`). Menu de contexto já tem padrão de item com
  `CheckOnClick` persistido (`Start with Windows`).
- **cswap (fonte: código em
  `~\AppData\Roaming\uv\tools\claude-swap\Lib\site-packages\claude_swap\`):**
  - `--switch-to <num> [--json]` é não-interativo; `Invoke-Cswap` já fecha stdin.
  - Há guarda de sessão viva (`_ensure_no_live_session` / warning no
    `_perform_switch`): a troca pode ser **recusada enquanto houver instância
    Claude viva** na conta. O CLAUDE.md do app confirma esse comportamento.
  - Existe `--switch-to <num> --force`, que ativa a credencial guardada **sem
    fazer backup do login vivo**. Se o token vivo tiver sido rotacionado depois
    do último backup, o force descarta a versão fresca — refresh token é uso
    único, isso pode **quebrar a conta**. Portanto: **PROIBIDO usar `--force`
    no fluxo automático.**

## A regra de decisão (o coração da feature)

Para cada conta com `Status = 'ok'` e barras presentes, defina o instante em que
ela fica/estará utilizável:

```
usable_at(conta):
    se barra 7d existe e 7d.Pct >= 100  ->  7d.ResetsAt      # bloqueio semanal manda
    senão se barra 5h existe e 5h.Pct >= 100 -> 5h.ResetsAt  # bloqueio de sessão
    senão                                ->  agora            # utilizável já
```

Isso implementa exatamente o pedido: compara-se o reset da 5h, **exceto** que
uma conta com a semanal estourada usa o reset da própria 7d (ela está inutilizável
até lá, não importa a 5h).

**Gatilho e alvo:**

- A decisão roda ao fim de cada `Complete-Refresh` (dados recém-chegados).
- **Só dispara se a conta ATIVA estiver bloqueada** (`usable_at(ativa) > agora`).
  Enquanto a conta ativa está utilizável, nunca trocar — isso elimina
  flapping (ex.: logo após um reset, a janela nova da conta ativa empurra o
  `ResetsAt` dela para +5h; sem este gatilho, o app "acharia" a outra conta
  melhor e ficaria pingue-pongueando).
- Alvo = conta com **menor `usable_at`** entre as elegíveis. Empate ou alvo ==
  ativa → não faz nada. Conta sem dados (`Status != 'ok'`, sem barra 5h) não é
  elegível como alvo.
- Com 2 contas isso degenera para o óbvio: ativa travou → se a outra está
  utilizável, troca já; se as duas travaram, troca para a que reseta primeiro
  (respeitando a regra da 7d). Mas implemente o caso geral (N contas) — é o
  mesmo `argmin` e o cswap suporta N.

**Decisão de interpretação (validar com o Gabriel se discordar):** o gatilho
"só quando a ativa trava" é inferência minha — a frase dele não fixa o momento
da troca. É a única leitura que não causa flapping, então foi a adotada.

## Guardas (todas obrigatórias)

1. **Nunca decidir sobre snapshot de boot:** exigir `$script:stale -eq $false`
   e `$script:updatedAt` recente (mesmo round). O snapshot pinta a UI, não
   alimenta decisão (espírito do invariante nº 5).
2. ~~Cooldown de 10 min entre trocas automáticas~~ — **removido em 17/07/2026,
   na mesma execução**, depois de descobrir (ver Descobertas da F1, item 2)
   que a troca pode reverter sozinha minutos depois (hipótese: outra sessão
   Claude Code viva reescrevendo `~/.claude.json`). Um cooldown cego mascararia
   exatamente esse cenário — ficaria "confiando" numa troca já desfeita pelo
   tempo inteiro do timer. `Get-AutoSwitchTarget` já é auto-suficiente contra
   oscilação por si só (só dispara com a ativa travada; devolve `$null` quando
   a própria ativa já é a melhor opção, inclusive quando ela É o alvo da
   última troca) — um temporizador em cima não somava proteção real. Decisão
   validada com o Gabriel em conversa depois da execução da F1-F3; ver
   `CLAUDE.md` invariante nº12.
3. **Não rodar se** `$script:busy` estiver setado, ou se uma troca/remoção
   manual estiver em curso, ou se o toggle estiver desligado.
4. **`--force` jamais** (risco de perder refresh token rotacionado — ver acima).
5. **Recusa do cswap não é erro fatal:** se a troca falhar (sessão Claude viva,
   por exemplo), notificar **uma vez por episódio de bloqueio** via balloon e
   tentar de novo no próximo refresh (a condição segue sendo reavaliada a cada
   60s). Sem MessageBox — fluxo automático não abre modal na cara do usuário
   (armadilha nº 4 do PS 5.1: e modal aqui seria pior que o problema).
6. **Confirmar a troca por `Get-ActiveAccountNum`**, nunca pelo exit code
   (invariante nº 3).
7. Todo o código novo chamado de dentro de `Timer.Tick` fica em `try/catch`
   (armadilha nº 4).

## Fases de execução

### F1 — Verificações empíricas (antes de escrever a feature)

1. Rodar `.\claude-usage-tray.ps1 -Once` e conferir no JSON real: labels exatos
   das barras (`5h`/`7d`), formato do `ResetsAt` (ISO parseável), shape com as
   duas contas.
2. Com uma instância `claude` aberta, rodar `cswap --switch-to <outra> --json`
   manualmente e registrar: recusa ou warning? qual mensagem/campo no JSON?
   (Isso calibra a detecção de "recusou" na F3.)
3. Anotar os resultados **neste arquivo**, seção "Descobertas da F1".

### F2 — Núcleo: decisão pura + settings

1. Criar `settings.json` em `$script:stateDir` com `{ "autoSwitch": true }`
   (default **ligado**). Funções `Load-Settings`/`Save-Settings` no padrão de
   `Load-Snapshot`/`Save-Snapshot` (try/catch silencioso, `-Encoding UTF8`).
2. Funções **puras** (sem estado de UI, testáveis por dot-source):
   - `Get-UsableAt($acct)` → `[datetimeoffset]` conforme a regra acima
     (retorna `[datetimeoffset]::Now` se utilizável; `$null` se inelegível).
   - `Get-AutoSwitchTarget($accounts)` → conta-alvo ou `$null` (aplica gatilho
     "ativa bloqueada" + argmin + inelegibilidades).
   - Usar `>= 100` no Pct (ele já chega arredondado como int).
3. Teste rápido: dot-source do `.ps1` é inviável (ele sobe a UI), então validar
   as funções com fixtures colando-as num script de teste temporário em
   `temp/` (criar a pasta; não commitar), com 4 cenários: ativa ok (não troca),
   ativa 5h=100% e outra livre (troca), ambas 5h=100% (troca p/ menor reset),
   ativa 5h=100% e outra com 7d=100% resetando depois (não troca p/ ela).

### F3 — Execução da troca + notificação

1. `Invoke-AutoSwitch` chamada no fim de `Complete-Refresh` (depois de
   `Update-TrayIcon`), embrulhada em try/catch, respeitando as guardas 1–4.
2. Fluxo: alvo existe → `Invoke-Cswap @('--switch-to', "$($alvo.Num)")` →
   confirmar com `Get-ActiveAccountNum` → sucesso: `$notify.ShowBalloonTip`
   ("Conta trocada automaticamente para N (email) - conta anterior reseta HH:mm",
   usar `Format-ResetClock`) + `Start-Refresh` (mesmo pós-troca do fluxo manual).
3. Recusa/falha: balloon único por episódio (flag `$script:autoSwitchWarned`,
   zerada quando a ativa volta a ficar utilizável ou a troca sucede), sem modal,
   e nada mais — o retry é implícito no próximo refresh.
4. ⚠️ O `.ps1` é **ASCII puro** (invariante nº 8): textos de balloon sem
   acento, ou glifos via `[char]0xNNNN`.

### F4 — UI mínima

1. Item no menu de contexto: `Auto-switch de conta` com `CheckOnClick`,
   inicializado do settings e persistindo no clique — espelhar o padrão do
   `Start with Windows` (linhas ~1341–1345).
2. Nada além disso no popup (YAGNI; o hover continua não esperando rede —
   invariante nº 4).

### F5 — Build, verificação end-to-end e documentação

1. Matar instância antiga (`Get-Process 'Claude Usage Tray' | Stop-Process -Force`
   — o guard de instância única mata lançamentos novos em silêncio), rebuildar
   com `build.ps1`, rodar o **exe direto** (nunca `powershell -WindowStyle
   Hidden` aninhado — o Defender mata como PowhidSubExec.B).
2. Verificação real: com o limite de sessão atingido na conta ativa (situação
   frequente esta semana) ou simulando via fixture no `-Once`, observar uma
   troca automática de ponta a ponta: balloon + `sequence.json` com o novo
   `activeAccountNumber` + popup refletindo a conta nova.
3. Documentar:
   - `README.md`: a feature, a regra de decisão e o toggle.
   - `CLAUDE.md` do projeto: novos invariantes — **auto-switch nunca usa
     `--force`**; **decisão só com dados frescos (nunca snapshot)**; **recusa
     vira retry silencioso + balloon único, nunca modal**.
   - Consolidado em `C:\Dev\consolidado\claude-usage-tray\CONSOLIDADO-2026-07-17.md`
     (autocontido: o que mudou, arquivos, decisões, pendências).

## O que NÃO fazer

- `cswap --switch-to --force` em qualquer caminho automático.
- Decidir com dados do snapshot ou de conta com `Status != 'ok'`.
- MessageBox/modal em fluxo automático.
- Reintroduzir cache por conta ou "lastGood" (invariante nº 5).
- Mexer no anel do ícone (segue sendo a 5h da conta ativa — invariante nº 6)
  ou nas janelas `scoped` (fora do escopo).
- Trocar enquanto a conta ativa está utilizável ("otimização" proativa = flapping).

## Riscos aceitos

- Se o cswap recusar a troca enquanto houver sessão Claude viva, o auto-switch
  fica em retry até o usuário fechar as janelas — é o comportamento seguro
  possível sem `--force`. O balloon avisa uma vez.
- Janela de até 60s (ou até 10min sob backoff de 429) entre o bloqueio real e a
  detecção — inerente à cadência de coleta; aceitável para o caso de uso.

## Descobertas da F1

1. **Shape real do `-Once`** (2 contas, num 1 e 4): labels confirmados `5h`/`7d`/
   `Fable` (scoped). `ResetsAt` é ISO parseável (`2026-07-17T15:59:59.760108+00:00`)
   quando a barra tem consumo. **Achado não previsto:** quando `Pct = 0` (sem
   janela ativa), `ResetsAt` vem **string vazia** (`""`), não nula/ausente. A
   conta 1 estava com `5h.Pct = 100` (bloqueada de verdade) no momento do teste —
   caso real de conta travada, útil de referência.
2. **Teste de recusa com sessão viva — revisado.** Primeira rodada: `cswap
   --switch-to 1 --json` com esta própria sessão Claude Code ativa (conta
   ativa = 4) respondeu `"switched": true`, mas checando alguns segundos depois
   `sequence.json`/`.claude.json` ainda apontavam pra conta 4. Lendo o
   código-fonte de `switch_to()`/`_perform_switch()` (instalação local,
   `switcher.py`), **não existe bloqueio duro por sessão viva no switch** —
   isso só existe em `remove_account` (`_ensure_no_live_session`, levanta
   erro); no switch uma sessão viva gera só um **aviso**, nunca bloqueia a
   escrita. Refeito o teste com monitoramento a cada 0,3s por 6s: **a troca
   persistiu normalmente** dessa vez — não reproduziu o comportamento da
   primeira rodada. Mecanismo do primeiro resultado seguiu sem explicação
   definitiva (hipótese: corrida com esta própria sessão reescrevendo
   `.claude.json` da memória). **Conclusão prática, sem mudança na F3:**
   `Get-ActiveAccountNum` continua sendo a única fonte confiável de "a troca
   aconteceu" — não porque o switch seja normalmente recusado, mas porque o
   corpo do JSON não é garantia suficiente mesmo quando o switch normalmente
   funciona. Ver `CLAUDE.md` armadilha nº4 (corrigida) para o texto final.
3. **Consequência para `Get-UsableAt` (F2):** como `ResetsAt` pode vir `""`
   mesmo esperado (quando `Pct < 100`), a função só tenta parsear `ResetsAt`
   quando `Pct >= 100`. Se ainda assim vier vazio/improcessável nesse caso
   (não observado, mas não descartado), tratar como indeterminado (`$null`) em
   vez de assumir "utilizável agora" ou "nunca" — indeterminado exclui a conta
   de ser alvo e não dispara troca se for a própria ativa (mais seguro que
   adivinhar).
