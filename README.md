# Bot de Divulgação de Promoções (Afiliados) via WhatsApp + n8n

Projeto de afiliado: descobre ofertas com desconto no Mercado Livre e na Amazon.com.br e posta
automaticamente num grupo de WhatsApp, com preço antes/depois e link de afiliado. Roda na mesma
VPS do projeto [`price-monitor-n8n`](../price-monitor-n8n), reaproveitando a mesma instância de
n8n, Postgres e Evolution API — só com tabelas e workflows novos, e um grupo de WhatsApp diferente
(esse é um bot de divulgação, não um assistente pessoal).

Design completo: [docs/superpowers/specs/2026-07-13-promo-poster-design.md](docs/superpowers/specs/2026-07-13-promo-poster-design.md)

## Estrutura

- `sql/001_init_schema.sql` — schema Postgres (`search_categories`, `deal_candidates`, `posted_deals`)
- `workflows/buscar-ofertas-ml.json` — descoberta de ofertas no Mercado Livre (cron 30 min)
- `workflows/buscar-ofertas-amazon.json` — descoberta de ofertas na Amazon (cron 30 min, offset)
- `workflows/selecionar-e-postar.json` — filtra, deduplica, gera link de afiliado e posta no grupo (cron 30 min, offset)

## Como funciona a descoberta

**Mercado Livre**: duas requisições por candidato.
1. `GET lista.mercadolivre.com.br/{keyword}` com `User-Agent: WhatsApp/2.23.20.0 A` (o mesmo truque
   validado no `price-monitor-n8n` — o ML libera bots de link-preview do bloqueio anti-bot normal).
   Essa página devolve um `@graph` JSON-LD com vários produtos de uma vez (nome, imagem, preço
   atual, link) — confirmado em 2026-07-13, 48 produtos num teste com a keyword "suplementos".
2. Pra cada candidato (até 15 por keyword), busca a página individual do produto com o mesmo
   User-Agent, só pra pegar o preço **original** — a listagem não traz isso, mas a página de
   produto tem `aria-label="Antes: X reais"` quando há desconto ativo.

**Amazon**: uma requisição só por keyword.
- `GET amazon.com.br/s?k={keyword}` com User-Agent de navegador comum (caminho leve, sem bot UA
  especial). A própria página de busca já traz preço atual E original (`De: R$ X`) juntos por
  item — mais simples que o ML. **Atenção**: a resposta vem comprimida, o node HTTP Request do n8n
  descomprime automaticamente; se testar via `curl` fora do n8n, usar `--compressed`.
- Cada card de produto é delimitado por `data-asin="XXXXXXXXXX"` no HTML — a extração corta o
  documento nesses pontos antes de aplicar os regexes de preço/nome/imagem, pra não misturar dados
  de produtos diferentes.

Ambas as lógicas de extração foram testadas contra HTML real capturado em 2026-07-13 antes de
serem escritas nos workflows (não são só sintaticamente válidas — rodaram e extraíram dados
corretos de verdade).

## Link de afiliado do Mercado Livre

Resolvido em 2026-07-14 via investigação com DevTools na ferramenta Linkbuilder
(`mercadolivre.com.br/afiliados/linkbuilder#hub`). O node "Gerar Links Afiliados ML" (dentro de
`selecionar-e-postar.json`, roda antes do loop de postagem) chama em lote a API interna que a
própria ferramenta usa:

```
POST https://www.mercadolivre.com.br/affiliate-program/api/v2/affiliates/createLink
Body: { "urls": [...], "tag": "SEU_TAG_DE_AFILIADO" }
```

**Atenção**: autenticação é por **sessão de navegador (cookie + CSRF token)**, não um token de API
estável — os dois valores (constantes `ML_COOKIE` e `ML_CSRF_TOKEN` no topo do node) precisam ser
atualizados periodicamente quando a sessão expirar. Processo pra renovar: abrir o Linkbuilder
logado, DevTools → Network → Fetch/XHR, gerar um link de teste, achar a chamada `createLink`,
copiar os headers `Cookie` e `X-Csrf-Token` de novo. **Nunca commitar esses valores reais no
repositório** — só editar direto no node, na instância do n8n. Se a sessão expirar sem você notar,
o node falha silenciosamente e o link cai pra URL normal do produto (sem afiliado) em vez de
travar a postagem inteira — vale checar de vez em quando se os posts de ML estão saindo com
`meli.la/...` (afiliado) ou com o link completo do produto (sessão expirada).

A Amazon é mais simples e não tem essa fragilidade — concatena `?tag=` direto na URL, sem sessão
nenhuma envolvida.

## Limitações conhecidas

- Assim como no `price-monitor-n8n`, o truque de User-Agent do Mercado Livre é um comportamento
  observado, não uma política documentada — pode parar de funcionar sem aviso.
- Sem geração de cupom de desconto ainda — é best-effort e depende de descobrir se a página expõe
  essa informação de forma acessível (não investigado a fundo ainda).
- Sem Shopee — proteção anti-bot forte demais, já descartada no `price-monitor-n8n`.
