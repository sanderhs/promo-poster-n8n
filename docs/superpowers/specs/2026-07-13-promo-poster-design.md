# Bot de Divulgação de Promoções (Afiliados) — Design

## Objetivo

Automatizar um grupo de WhatsApp com promoções descobertas ativamente no Mercado Livre e na
Amazon.com.br, postando produto + preço antes/depois + link de afiliado, pra monetizar os
programas de afiliados do usuário nessas duas plataformas.

Projeto separado de `price-monitor-n8n` (que monitora produtos específicos cadastrados pelo
usuário e avisa só ele quando o preço cai), mas reaproveita a mesma infraestrutura: a mesma VPS,
mesma instância do n8n, mesmo Postgres (tabelas novas no schema existente), mesma instância da
Evolution API (WhatsApp) — só aponta pra um grupo novo, dedicado a divulgação.

## Arquitetura

Três workflows n8n, todos em cron de 30 em 30 minutos, escalonados pra não bater nas duas
plataformas ao mesmo tempo:

```
Buscar Ofertas ML  ──┐
                      ├──> deal_candidates (staging) ──> Selecionar e Postar ──> grupo WhatsApp
Buscar Ofertas Amazon ┘
```

- **`Buscar Ofertas ML`** e **`Buscar Ofertas Amazon`** rodam a descoberta de forma independente
  e só gravam candidatos numa tabela de staging — não postam nada diretamente. Isso permite testar
  cada descoberta isoladamente (rodar manualmente e inspecionar `deal_candidates`) sem nunca
  disparar uma mensagem real no grupo.
- **`Selecionar e Postar`** roda depois dos dois, lê os candidatos acumulados, aplica filtro de
  desconto mínimo e deduplicação, seleciona os melhores, gera os links de afiliado e posta.

Separar descoberta de postagem também facilita adicionar uma terceira plataforma no futuro sem
tocar na lógica de seleção/postagem.

## Dados (Postgres — schema existente na VPS, tabelas novas)

### `search_categories`
Categorias/palavras-chave de interesse, editadas manualmente via SQL.

| coluna     | tipo    | notas                                  |
|------------|---------|-----------------------------------------|
| id         | serial  | PK                                      |
| keyword    | text    | termo de busca (ex: "suplementos")     |
| platform   | text    | `'ml'`, `'amazon'` ou `'both'`          |
| active     | boolean | default true                            |
| created_at | timestamptz | default now()                       |

### `deal_candidates`
Staging — cada rodada de descoberta insere aqui. Não é fonte de verdade de "já postado".

| coluna         | tipo    | notas                                          |
|----------------|---------|--------------------------------------------------|
| id             | serial  | PK                                                |
| platform       | text    | `'ml'` ou `'amazon'`                              |
| product_id     | text    | ID do produto na plataforma (ex: MLB123, ASIN)   |
| product_url    | text    | URL original (sem link de afiliado)               |
| product_name   | text    |                                                    |
| image_url      | text    |                                                    |
| current_price  | numeric |                                                    |
| original_price | numeric | nullable — nem toda oferta tem preço "de"        |
| discount_pct   | numeric |                                                    |
| coupon_code    | text    | nullable — best-effort, pode não estar disponível |
| found_at       | timestamptz | default now()                                 |

### `posted_deals`
Uma linha por produto já postado — usada só pra deduplicação.

| coluna            | tipo    | notas                                    |
|-------------------|---------|--------------------------------------------|
| id                | serial  | PK                                          |
| platform          | text    |                                              |
| product_id        | text    |                                              |
| last_posted_price | numeric |                                              |
| last_posted_at    | timestamptz |                                          |

Índice único em `(platform, product_id)` pra permitir upsert direto.

## Workflows

### `Buscar Ofertas ML` (cron 30 min)

1. `SELECT keyword FROM search_categories WHERE platform IN ('ml','both') AND active = true`
2. Pra cada keyword: GET numa página de busca/ofertas do Mercado Livre com
   `User-Agent: WhatsApp/2.23.20.0 A` (mesmo header validado no `price-monitor-n8n` pra página de
   produto individual — **ainda não confirmado pra página de listagem/busca**, é o primeiro passo
   do plano).
3. Extrai candidatos da resposta (nome, preço atual, preço original, %desconto, imagem, url,
   product_id) — via JSON-LD ou o mesmo padrão de card embutido observado na página
   `/social/urubupromo` durante a investigação do projeto anterior.
4. Filtra localmente por `discount_pct >= 20`.
5. Insere os que passam em `deal_candidates`.

### `Buscar Ofertas Amazon` (cron 30 min, offset de ~10 min do ML)

1. `SELECT keyword FROM search_categories WHERE platform IN ('amazon','both') AND active = true`
2. Pra cada keyword: GET numa página de busca/ofertas da Amazon.com.br com header `User-Agent` de
   navegador comum (caminho leve já validado no projeto anterior pra produto individual — a
   confirmar se a página de busca/listagem tem o mesmo formato de preço embutido).
3. Extrai candidatos (mesmo formato acima) via regex sobre `"priceAmount"`/JSON-LD, igual ao
   `price-monitor-n8n`.
4. Filtra por `discount_pct >= 20`.
5. Insere em `deal_candidates`.

### `Selecionar e Postar` (cron 30 min, alguns minutos depois dos dois anteriores)

1. Lê candidatos de `deal_candidates` inseridos desde a última execução.
2. `LEFT JOIN` com `posted_deals` por `(platform, product_id)`: inclui o candidato se nunca foi
   postado, OU se `current_price < last_posted_price` (repostagem só se o preço caiu ainda mais
   desde a última vez).
3. Ordena por `discount_pct` desc, pega os **top 3–5**.
4. Pra cada selecionado:
   - Gera o link de afiliado:
     - **Amazon**: concatena `?tag=SEUTAG-20` (ou `&tag=...`) na `product_url`.
     - **Mercado Livre**: chama o mecanismo identificado na investigação do Linkbuilder (ver
       "Pendências" abaixo).
   - Monta a mensagem (formato abaixo).
   - Posta no grupo via `sendMedia` da Evolution API (imagem + legenda).
   - Faz upsert em `posted_deals` com o preço e timestamp atuais.

## Formato da mensagem

Imagem do produto (mídia nativa da Evolution API) + legenda:

```
{emoji} *{nome do produto}*

De ~R$ {preço original}~
Por *R$ {preço atual}* 🔥 (-{desconto}%)
{se houver cupom: 🎟️ Cupom: {código}}

👉 Pegar promoção: {link de afiliado}

🛒 {Mercado Livre / Amazon}
```

Cupom é best-effort: só entra na mensagem se a extração encontrar essa informação na página; não
bloqueia a postagem se não encontrar.

## Erros e tolerância a falhas

Mesmo padrão do `price-monitor-n8n`: `continueOnFail` nos nodes HTTP de busca, itens que falharem
a extração são simplesmente ignorados (não geram candidato), sem travar o restante da rodada.

## Pendências / primeiros passos do plano de implementação

1. **Validar extração em página de busca/listagem** (ML e Amazon) com o mesmo tipo de User-Agent
   usado no projeto anterior — testar fora do n8n primeiro (`curl`), confirmar formato dos dados.
2. **Investigar o mecanismo do Linkbuilder do Mercado Livre**: usuário abre a ferramenta
   (`mercadolivre.com.br/afiliados/linkbuilder#hub`), usa o modo de lote com DevTools abertas (aba
   Network), e identificamos a chamada por trás — se for uma API JSON chamável com uma sessão
   salva, integra direto via HTTP Request node no n8n; se não for automatizável de forma limpa, o
   plano B é Playwright com perfil de navegador autenticado e persistente.
3. **Confirmar disponibilidade de dado de cupom** nas páginas de produto de cada plataforma
   (best-effort, não bloqueia o resto do projeto se não for viável).

## Fora de escopo (por ora)

- Shopee — já confirmado no `price-monitor-n8n` que a proteção anti-bot dela é forte demais pra
  esse tipo de abordagem leve.
- Geração de imagem customizada (card com tarja/moldura) — usar mídia nativa (foto + legenda) em
  vez disso.
- Multi-usuário / múltiplos grupos de destino.
