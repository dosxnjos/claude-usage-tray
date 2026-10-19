# 2026-08-03 — consumir `lastGoodUsage` do cswap 0.24 e corrigir o mapa de status

## Contexto (por que isto existe)

Sintoma relatado: o `cswap --list` mostrava as barras normalmente, mas o tray
ficava vazio — e reiniciar não resolvia.

Cadeia causal apurada nesta sessão, com o cswap ainda em 0.23.0:

1. A conta ativa estava **at-limit na janela do Fable** (100%), e o Fable entra
   na janela vinculante porque esta máquina tem `autoswitch.model = Fable`.
2. `poll_policy.plan_after_fetch` empurrava o `nextPollAt` de uma conta at-limit
   direto para o reset da janela (3 dias à frente). O store congelou às 14:07.
3. O `--list` **texto** segue mostrando o último valor conhecido, anotado com a
   idade (`· 8h ago`). O `--list --json` — a fonte do tray — serve
   `decision_value()`, que só entrega last-good enquanto ≤ `STALE_OK_S` (300s).
   Com 8h de idade virou `usage: null`, `usageStatus: "unavailable"`.
4. O tray, por invariante nº5 (nunca pintar número velho), mostrou o motivo:
   barra vazia.

**Resolvido a montante:** upgrade 0.23.0 → 0.24.1. A release 0.24.0 traz
`fix(usage): keep exhausted accounts polling` (#182) — exatamente o passo 2. O
poll voltou ao normal na hora, sem tocar em nada local.

A mesma release traz `feat(json): expose display-grade last-good usage` (#170):
quando o dado é velho demais para decidir, o `--json` passa a carregar
`lastGoodUsage` / `lastGoodFetchedAt` / `lastGoodAgeSeconds` além do `usage:
null`. Isso **muda a premissa da invariante nº5**: o número velho agora vem
rotulado com a idade, então dá para exibi-lo sem enganar. Decisão do Gabriel
nesta sessão: passar a exibir (opção "b").

Bug independente achado no caminho: `Map-CswapStatus` casa com as strings
antigas separadas por espaço (`'token expired'`, `'re-login needed'`, …), mas o
cswap emite **snake_case** (`token_expired`, `relogin_required`,
`no_credentials`, `keychain_unavailable`, `api_key`). Hoje só `ok` bate — todo o
resto cai no default e o popup diz "API indisponivel", que é falso. Prova: a
conta 5 está `relogin_required` no JSON e o tray reporta `offline`.

## Decisões

- **Não** fazer coleta própria de usage no tray (ideia levantada e descartada):
  o budget do endpoint de usage é **por access token**, não por processo
  (medido pelo próprio cswap, `poll_policy`), então uma segunda engine competiria
  pelo mesmo orçamento e derrubaria as duas em 429; e manter token vivo por
  fora significaria escrever credencial — refresh token é de uso único.
  Invariantes nº1/nº10/nº12 seguem valendo: o tray só desenha.
- **Invariante nº5 é revisada, não revogada:** continua proibido pintar número
  velho **como se fosse atual**. O que passa a ser permitido é o last-good do
  cswap, sempre com a idade visível e visualmente apagado.
- Barra stale é desenhada em cinza (`$cTrack` claro), não na escala
  verde/amarelo/vermelho: o nível continua legível, a cor deixa de comunicar
  urgência sobre um dado que pode ter virado.

## Passos

### 1. `Map-CswapStatus` entende o vocabulário atual do cswap

`claude-usage-tray.ps1`, função na ~linha 365. Aceitar snake_case **e** as
formas antigas com espaço (custo zero, sobrevive a um rollback do cswap):

| `usageStatus` do cswap | token interno |
| --- | --- |
| `ok` | `ok` |
| `token_expired` / `token expired` | `expired` |
| `relogin_required` / `re-login needed` | `relogin` |
| `no_credentials` / `no credentials` | `notoken` |
| `api_key` / `api key` | `apikey` |
| `keychain_unavailable` / `keychain unavailable` | `offline` |
| `unavailable` | `nodata` (novo) |
| desconhecido não-vazio | `nodata` |

`nodata` é novo e existe para separar "o cswap não tem medição recente" de
"a API está fora" — hoje os dois dizem a mesma frase errada.

**Pronto quando:** `-Once` reporta `relogin` na conta 5 (hoje reporta `offline`).

### 2. Coleta: cair no `lastGoodUsage` quando `usage` for null

No `$script:Collect`, ramo do cswap (~linha 392). Se `$ac.usage` estiver null e
`$ac.lastGoodUsage` existir, montar as barras a partir dele e marcar a conta:

- `Stale = $true`
- `AgeS  = $ac.lastGoodAgeSeconds`

Campos novos atravessam a fronteira de runspace de graça (o Collect já devolve
JSON string e `ConvertFrom-CollectJson` repassa os objetos inteiros).

**Pronto quando:** `-Once` traz a conta 5 com `Stale: true`, `AgeS: ~177000` e
as barras 5h/7d preenchidas.

### 3. `Format-Age` — idade em texto ASCII

Helper novo: segundos → `45s` / `8m` / `3h` / `2d`, sufixo ` atras`.
⚠️ O `.ps1` é **ASCII puro** (invariante nº8): sem acento, sem glifo literal.

### 4. Desenho

- `New-Bar`: aceitar cor de preenchimento opcional (default = `Get-UsageColor`).
- `Add-UsageRow`: aceitar `$stale`; barra cinza e linha de reset prefixada pela
  idade quando stale.
- Card ativo: quando `Stale`, desenhar as barras + uma linha
  `medicao de <idade> - <motivo>` no lugar do "sem dados - <motivo>".
- Linha compacta: o canto direito hoje diz `agora` quando há dado; passa a dizer
  a idade quando o dado é stale.
- `New-RingIcon`/`Update-TrayIcon`: anel em cinza quando o valor exibido é
  stale — o ícone não pode afirmar "24%" com a mesma autoridade de um dado
  fresco. (O `-Preview` já chama `New-RingIcon $p $false`, um segundo argumento
  que a assinatura atual ignora; a assinatura passa a ter esse parâmetro.)

**Pronto quando:** `-Preview` gera `popup.png` com a conta 5 mostrando barras
cinzas + "2d atras", e `icons.png` continua legível.

### 5. Documentação

- `CLAUDE.md`: reescrever a invariante nº5 (revisão, com o porquê da mudança de
  premissa) e anotar em nº1 que a versão mínima do cswap agora é **0.24.0**
  (o `lastGoodUsage` não existe antes disso; sem ele o comportamento degrada
  para o de hoje, sem quebrar).
- `README.md`: a frase sobre "nunca mostra número velho" precisa acompanhar.

## Fora de escopo (registrado, não feito aqui)

Fusão com o cswap upstream (`cswap tray` para Windows, equivalente ao
`cswap menubar` do macOS) e portabilidade. Discussão e requisitos ficam no
diário de 2026-08-03; exige reescrita em Python, não é porte do `.ps1`.

> Auditado em 2026-09-01 (overhaul): FECHADO — commit 11b35ce (03/08); lastGoodUsage 9 ocorrências no .ps1
