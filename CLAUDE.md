# claude-usage-tray — regras para mexer neste código

App de bandeja do Windows que mostra o uso das contas Claude no hover.
PowerShell 5.1 + WinForms, empacotado com `ps2exe`. Visão geral, dados e decisões
de produto estão no [`README.md`](README.md) — este arquivo é só o que **quebra**
se você ignorar.

**Memória/decisões deste projeto:** `C:\Dev\cerebro\projetos\claude-usage-tray.md`
(local desta máquina — ler antes de decisão não-trivial: pendências abertas,
decisões recentes).

## Invariantes

1. **A fonte de dados é `cswap --list --json`, não a API direta.** O `Collect`
   roda `cswap --list --json` no runspace de fundo e mapeia a saída. Isso é
   deliberado e resolve três coisas que a chamada direta não resolvia:
   (a) o cswap **refresha tokens expirados** de contas inativas e reescreve o
   `.enc`, então uma conta morta volta sozinha — nós continuamos read-only, é o
   cswap que rotaciona; (b) o orçamento do endpoint de usage é **por access
   token**, não por processo (medido pelo próprio cswap, ver `poll_policy.py`),
   e o cswap concentra todas as suas superfícies num store compartilhado com
   cadência adaptativa e backoff de 429 — uma segunda engine pollando por fora
   não ganharia dado, dividiria o mesmo orçamento e derrubaria as duas em 429;
   (c) ele já traz as janelas **por modelo** (`scoped[]`, ex. Fable). Há um
   fallback (API direta, conta logada) só para quando o cswap não está instalado.
   Nós nunca escrevemos `sequence.json`/`.enc` — trocar/remover também vão pelo
   `cswap` (`Invoke-Cswap`).

   ⚠️ **Versão mínima: cswap 0.24.0** (invariante nº5 depende do `lastGoodUsage`,
   nascido lá). Com um cswap mais velho nada quebra — o campo só não vem e a
   conta lê como "sem dados".

   ⚠️ **O vocabulário de `usageStatus` é snake_case** (`token_expired`,
   `relogin_required`, `no_credentials`, `keychain_unavailable`, `api_key`,
   `unavailable`), não as strings com espaço da grafia antiga. `Map-CswapStatus`
   aceita as duas; se você acrescentar um status, acrescente nas duas grafias.
   Histórico: o mapa ficou preso na grafia antiga e **todo** status virava
   "API indisponivel" — uma conta pedindo re-login era reportada como queda da
   API (corrigido em 03/08/2026).

2. **Status vem do `usageStatus` do cswap, mapeado em `Map-CswapStatus`.**
   `ok`/`token expired`→`expired`/`re-login needed`→`relogin`/`no credentials`→
   `notoken`/`api key`→`apikey`/`keychain unavailable`→`offline`. Nunca reportar
   "token expirado" para o que não é 401 — no fallback direto, um 429 é
   `ratelimited`, não `expired`. `Format-Status` traduz para o texto da UI.

3. **Nunca confiar no exit code do `cswap` para saber se a ação aconteceu.**
   `cswap remove` responde **exit 0 também quando o usuário cancela**, e ele se
   recusa a remover/trocar enquanto houver sessão Claude viva na conta
   (`_ensure_no_live_session`). Confira o `sequence.json` depois
   (`Test-AccountExists` / `Get-ActiveAccountNum`).

4. **O hover nunca espera a rede.** A coleta roda num runspace de fundo a cada
   60s e fica em memória; `Build-Popup` só desenha. Se você fizer o popup buscar
   dados na hora de abrir, perdeu o ponto do app.

5. **Nunca pintar número velho como se fosse atual — mas o velho *datado* vale.**
   (Revisada em 03/08/2026; a regra original era "só o último fetch, ponto".)
   O que continua proibido: **cache nosso**. Não reintroduza um `lastGood` ou
   back-fill do lado do tray — o snapshot em disco segue existindo só para
   pintar rápido no boot (o re-fetch de 3s corrige).

   O que passou a ser permitido: o **`lastGoodUsage` do próprio cswap**. Desde a
   0.24.0 o `--json` separa os dois grãos — `usage` é decision-grade (some assim
   que envelhece) e `lastGoodUsage` é display-grade, **acompanhado de
   `lastGoodAgeSeconds`**. Como o dado vem rotulado com a idade, dá para exibir
   sem enganar. Regra de desenho: barra em `$cStale` (fora da escala
   verde/âmbar/vermelho), percentual em `$cMuted`, anel da bandeja cinza, e a
   idade **sempre visível** ("8h atras" na linha compacta, "medicao de 8h atras"
   no card ativo). Nunca mostre o número sem a idade ao lado — é isso, e só
   isso, que a decisão original queria evitar.

   Por que a premissa mudou: em 03/08/2026 o tray ficou 8h em branco enquanto o
   `cswap --list` mostrava tudo. Causa: conta at-limit na janela do Fable →
   cswap adiava o poll até o reset (corrigido no cswap por #182) → `usage: null`
   no JSON → barra vazia. Um "24% · 8h atras" cinza teria informado; "sem dados"
   não informou nada.

6. **O ícone da bandeja é a janela de SESSÃO (5h), não o pior/semanal.**
   `Get-SessionPct` pega a barra `5h` (fallback: primeira barra). Se mudar para
   "pior janela", quebra o pedido.

   **A partir de `$TAIL_FROM_PCT` (95%) o anel troca de escala:** a faixa
   95→100 ocupa a volta inteira e um **ponto central** marca que a escala mudou.
   Motivo medido (04/08/2026, `temp/ring-lab.ps1`): no tamanho real de 16px,
   88/90/93/96/98/100% desenham o **mesmo ícone** — 2% de uso são 7° de arco,
   menos de um pixel na borda. Com o corte em 95, cada 1% restante vale 72° (um
   oitavo da volta), que é o que finalmente separa 98 de 99 de 100. Descartados
   na mesma comparação: borda externa vermelha (fina por definição, some no
   fundo escuro e ainda come pixel do anel) e trilho vermelho (contraste baixo
   demais sob arco vermelho).
   ⚠️ **Um limiar só.** Dois ou mais viram escalas que ninguém identifica de
   relance em 16px. O ponto usa a **cor do arco** — em dado stale ele é cinza:
   marca a escala, nunca afirma urgência sozinho.

7. **As linhas das outras contas mostram só 5h e 7d; o card ativo mostra tudo.**
   Barras `scoped` (Fable, etc.) apertariam a linha compacta — ficam só no card
   da conta ativa, que tem espaço. Pedido explícito: "as duas barras, sessão e
   semanal" para as outras contas.

8. **O arquivo `.ps1` é ASCII puro.** O PS 5.1 lê `.ps1` sem BOM como ANSI e
   corrompe literais não-ASCII. Glifos entram como `[char]0xNNNN`.

9. **Nunca use `cswap --switch-to --force`** (na troca manual — a automática
   nem passa mais por aqui, ver nº10). O `--force` ativa a credencial guardada
   **sem** fazer backup do login vivo primeiro; refresh token é de uso único,
   então se o vivo girou depois do último backup, o `--force` descarta a
   versão fresca e pode quebrar a conta. Sem exceções.

10. **O tray NÃO decide auto-switch — delega ao `cswap auto` (desde
    24/07/2026).** Com o toggle ligado, `$script:Collect` roda
    `cswap auto --once --json` no runspace de fundo ANTES de buscar a lista
    (uma troca já aparece no mesmo refresh) e devolve o envelope
    `{accounts, auto}`; `Show-AutoSwitchEvents` só traduz eventos em balões.
    A política inteira (threshold 90%, histerese 10 pts, cooldown 300s com
    escape at-limit, freshening de token, quarentena, failover,
    `autoswitch.model Fable` nesta máquina) é do cswap — ajuste com
    `cswap config set autoswitch.*`, nunca recriando decisão local
    (`Get-UsableAt`/`Get-AutoSwitchTarget` foram removidas de propósito:
    duas engines sobre as mesmas credenciais = corrida).

11. **Evento de auto-switch vira balão, nunca `MessageBox`.**
    `Show-AutoSwitchEvents` roda fora de qualquer clique do usuário (dispara
    do `Timer.Tick`); um modal aqui travaria a UI sem ninguém olhando.
    `switch` → Info; `account-quarantined` → Warning (o engine só emite na
    transição); `all-exhausted` → Warning **um por episódio**
    (`$script:autoSwitchWarned`, re-armado quando o tick sai com exit 0/2).
    O resto (below-threshold, histerese, erro transitório) é silêncio.

12. **Não adicione cooldown/temporizador do tray por cima do auto-switch.**
    O cooldown que existe é o do próprio cswap (300s, só proativo, com escape
    at-limit) — dono da decisão, dono do ritmo. História: um cooldown cego de
    10min no tray foi criado e removido em 17/07/2026; a decisão local
    inteira saiu em 24/07/2026 com a delegação.

## Armadilhas do PowerShell 5.1 (não são bugs deste código — não "conserte")

Todas verificadas na marra neste projeto, no PS 5.1 do Windows 11
(SMA 10.0.26100.8737).

1. **`@()` sobre `List[object]` criada com `New-Object` lança
   `ArgumentException`** ("Os tipos de argumento não correspondem"), vinda do
   binder do DLR (`PSToObjectArrayBinder` → `MaybeDebase` →
   `Expression.Condition`). Só quando o tipo do elemento é exatamente `object`:

   | expressão | resultado |
   | --------- | --------- |
   | `New-Object System.Collections.Generic.List[object]` + `@($x)` | **falha** |
   | `[System.Collections.Generic.List[object]]::new()` + `@($x)` | ok |
   | `List[string]`, `List[int]`, `ArrayList` + `@($x)` | ok |
   | `$x.ToArray()`, `[object[]]$x`, `foreach`, pipeline | ok |

   É o wrapper `PSObject` que o `New-Object` acrescenta. Por isso o coletor usa
   `ArrayList`.

2. **PSCustomObject não sobrevive à fronteira de runspace.** Devolver um
   `object[]` de PSCustomObjects de um `BeginInvoke()`/`EndInvoke()` entregava um
   array do tamanho certo com **todos os elementos `null`**. Por isso
   `$script:Collect` devolve uma **string JSON** e `ConvertFrom-CollectJson`
   reconstrói do lado do pai. Não "simplifique" devolvendo objetos.

3. **`ConvertFrom-Json` emite um array JSON como UM objeto**, sem desenrolar no
   pipeline: `@($json | ConvertFrom-Json)` dá `Count = 1` contendo o array.
   Percorra com `foreach` (é o que `ConvertFrom-CollectJson` faz).

4. **Exceção escapando de handler do WinForms vira caixa de diálogo modal de
   crash do .NET.** Num app de bandeja isso é pior que o bug que ela reporta.
   Todo `Timer.Tick` e todo evento do `NotifyIcon` tem `try/catch`.

5. **`Rectangle` é struct, mas o PowerShell entrega a mesma instância boxed na
   atribuição.** `$r = $script:anchor; $r.Inflate(8,8)` mutaria o original. Use
   `Grow-Rect`, que constrói um novo.

6. **`.GetNewClosure()` dentro de um scriptblock invocado com `&` NÃO captura
   variáveis do escopo avô.** `Set-RowInteractive` tentava capturar `$panel` num
   handler `MouseEnter` aninhado; no disparo, `$panel` resolvia para outro objeto
   e crashava com "propriedade 'BackColor' não encontrada". A correção robusta é
   guardar o contexto no `.Tag` de cada control e ler `$this.Tag` em runtime — o
   `$this` do handler é sempre o control que disparou.

7. **Handler de evento WinForms não deve escapar exceção** — vira caixa de
   diálogo modal de crash. Os handlers de menu/mouse/timer têm `try/catch`; o de
   `MouseEnter` acima escapou porque o erro era de binding, não de runtime nosso.

## Armadilhas de ambiente (Windows / Defender / cswap)

1. **Não teste o app lançando `powershell -WindowStyle Hidden -ExecutionPolicy
   Bypass` de dentro de outro PowerShell.** O Defender bloqueia esse padrão como
   `Trojan:Win32/PowhidSubExec.B` — é detecção **comportamental** da linha de
   comando (PowerShell abrindo PowerShell escondido com bypass), não do código.
   O processo é morto e o `stderr` sai vazio, o que parece um bug fantasma.
   Teste rodando o `.exe` direto, ou o `.ps1` em primeiro plano.

2. **O guard de instância única faz um segundo lançamento sair com código 0, em
   silêncio.** Se uma instância antiga ficou pendurada (teste anterior, ícone na
   bandeja), toda execução nova "morre na hora" sem erro. Antes de investigar,
   mate as instâncias: `Get-Process 'Claude Usage Tray' | Stop-Process -Force`.

3. **`cswap remove` é interativo:** pergunta `[y/N]` no `stdin`. Rodando sem
   console isso trava — por isso `Invoke-Cswap` sempre fecha o `stdin` e, na
   remoção, escreve `y` antes. E passe sempre o **número** da conta, nunca o
   e-mail: e-mail ambíguo abre outro prompt interativo.

4. **`switch_to()` NÃO tem bloqueio duro por sessão Claude viva** (isso existe
   só no `remove_account`/`_ensure_no_live_session`, que levanta erro). No
   switch, uma sessão "modo-`cswap run`" viva gera só um **aviso**
   (`warnings[]`) sobre token possivelmente ficar defasado — nunca impede a
   escrita. O caminho normal (`_perform_switch`, em `switcher.py` da instalação
   local) escreve credenciais + `.claude.json` + `sequence.json`
   incondicionalmente, sob lock. Verificado lendo o código-fonte em
   17/07/2026 (`~\AppData\Roaming\uv\tools\claude-swap\...\switcher.py`).

   **Mas já foi observado (uma vez, não reproduzido) `"switched": true` no
   JSON sem a troca persistir** — checagem alguns segundos depois mostrou
   `sequence.json`/`.claude.json` ainda na conta antiga. Um reteste imediato do
   mesmo comando, monitorado a cada 0,3s por 6s, mostrou a troca persistindo
   normalmente dessa vez. Mecanismo exato desconhecido — hipótese mais
   provável é uma corrida com esta própria sessão Claude Code (que mantém
   `.claude.json` em memória e pode reescrevê-lo com a identidade antiga em
   alguma rotina própria) — mas não é garantia, só um dado a favor de nunca
   confiar no corpo do JSON. Por isso `Get-ActiveAccountNum` (via
   `sequence.json`) continua sendo a única fonte confiável após o switch
   **manual**. (O automático saiu do tray em 24/07/2026 — invariante nº10:
   quem decide E escreve é o próprio `cswap auto`, sob os locks dele, o que
   fecha essa corrida para o caminho automático; e o refresh seguinte do tray
   reflete o que quer que esteja no disco.)

## Detalhes de implementação que parecem gambiarra mas não são

- **Reflexão nos campos privados `window` e `id` do `NotifyIcon`**
  (`Resolve-NotifyIconIds`) é a única forma de obter o `hwnd`/`uID` que o
  `Shell_NotifyIconGetRect` precisa. Sem o retângulo do ícone, um cursor **parado**
  sobre ele fecharia o popup, porque `MouseMove` para de disparar quando o mouse
  para. Há fallback (`$script:anchor`) se a reflexão falhar num .NET futuro.

- **`ShowWindow(hwnd, SW_SHOWNOACTIVATE)` em vez de `Show()`** para o popup de
  hover: `Show()`/`Visible = $true` roubaria o foco de onde o usuário está
  digitando. `Hide-Popup` chama `SW_HIDE` antes de `Hide()` porque a flag
  `Visible` do WinForms pode ficar dessincronizada nesse caminho.

- **`DestroyIcon` no handle antigo** a cada `Update-TrayIcon`:
  `Icon.FromHandle` não é dono do handle, e o ícone é redesenhado a cada minuto.
  Sem isso, vaza um handle GDI por refresh, para sempre.

## Diagnóstico

```powershell
.\claude-usage-tray.ps1 -Once            # coleta uma vez, imprime o JSON, sai
.\claude-usage-tray.ps1 -Preview .\out   # renderiza popup + anel em PNG
cswap auto --once --dry-run --json       # simula o tick de auto-switch (nunca troca)
```

O `-Once` é read-only por construção: o tick de auto-switch NÃO roda nele
(o argumento `$AutoTick` do Collect só é passado pelo `Start-Refresh`).

`-Preview` é a forma de conferir layout sem depender de passar o mouse num ícone
vivo: ele usa `DrawToBitmap` (WM_PRINT), então a janela nem precisa estar visível.
