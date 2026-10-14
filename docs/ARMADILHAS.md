# Armadilhas, gambiarras aparentes e diagnóstico do claude-usage-tray

Movido do `CLAUDE.md` em 14/10/2026, quando ele virou índice. Invariantes:
[INVARIANTES.md](INVARIANTES.md).

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
