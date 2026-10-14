# claude-usage-tray — índice das regras para mexer neste código

**Índice, não depósito**: só o que **quebra** se você ignorar, em 1 linha; o texto integral está nos
docs; quem acrescenta linha, corta outra. App de bandeja do Windows (PowerShell 5.1 + WinForms,
`ps2exe`) que mostra o uso das contas Claude no hover; visão geral e decisões de produto:
[README.md](README.md) · **hub** (pendências, decisões): `C:\Dev\cerebro\projetos\claude-usage-tray.md`.

## Leitura obrigatória

| se vai… | leia antes |
| --- | --- |
| mexer na coleta, no status, no popup, no ícone ou no auto-switch | [docs/INVARIANTES.md](docs/INVARIANTES.md) (12 invariantes, com o porquê) |
| achar que é bug do PowerShell, do Defender ou do cswap | [docs/ARMADILHAS.md](docs/ARMADILHAS.md) (não "conserte") |
| testar ou conferir layout | [docs/ARMADILHAS.md § Diagnóstico](docs/ARMADILHAS.md) (`-Once`, `-Preview`, `cswap auto --once --dry-run`) |

## Invioláveis

- Dado vem de `cswap --list --json` (mínimo 0.24.0), nunca da API direta; nunca escrevemos `sequence.json`/`.enc`.
- Status vem do `usageStatus` (snake_case) via `Map-CswapStatus`; 429 é `ratelimited`, nunca `expired`.
- Exit code do `cswap` não prova a ação: conferir o `sequence.json` depois.
- O hover nunca espera a rede; número velho só com a idade ao lado (o `lastGoodUsage` do cswap), nunca cache nosso.
- O ícone é a janela de 5h, com troca de escala única em 95%; linhas das outras contas só 5h e 7d.
- O `.ps1` é ASCII puro (glifo via `[char]0xNNNN`).
- Nunca `cswap --switch-to --force`; o tray **não** decide auto-switch (é do `cswap auto`), sem cooldown próprio, evento vira balão, nunca `MessageBox`.
- Teste rodando o `.exe` ou o `.ps1` em primeiro plano, nunca `powershell -WindowStyle Hidden -ExecutionPolicy Bypass` (o Defender mata).
