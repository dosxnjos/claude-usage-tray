# Invariantes do claude-usage-tray: o texto integral

Movido do `CLAUDE.md` em 14/10/2026, quando ele virou índice (régua:
`C:\Dev\roadmap\2026-10-14-melhoria-claude-md-raiz-indice.md`). O `CLAUDE.md` guarda uma linha
por invariante e aponta para cá. Armadilhas e diagnóstico: [ARMADILHAS.md](ARMADILHAS.md).

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

