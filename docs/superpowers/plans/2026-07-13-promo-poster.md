# Bot de Divulgação de Promoções Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this
> plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. **This plan requires access
> to the user's VPS** (n8n web UI and/or SSH + `psql`) and to the user's Mercado Livre affiliate
> account (Task 4) — it cannot be executed from a machine without that access. Confirm access
> before starting Task 1.

**Goal:** Deploy a working promo-poster bot: discovers deals with ≥20% discount on Mercado Livre
and Amazon.com.br every 30 minutes, and posts the best ones (with affiliate link) to a dedicated
WhatsApp group.

**Architecture:** Three independent n8n workflows sharing a Postgres staging table
(`deal_candidates`) and a dedup table (`posted_deals`). Two discovery workflows (`Buscar Ofertas
ML`, `Buscar Ofertas Amazon`) only write candidates; a third (`Selecionar e Postar`) reads,
filters, dedupes, generates affiliate links, and posts. See the design doc for full rationale:
[../specs/2026-07-13-promo-poster-design.md](../specs/2026-07-13-promo-poster-design.md).

**Tech Stack:** n8n (existing instance, shared with `price-monitor-n8n`), Postgres (same instance,
new tables), Evolution API (existing WhatsApp gateway, new destination group) — plain SQL + n8n
Code/HTTP Request/Postgres nodes, no external app code.

## Global Constraints

- Cron schedule: every 30 minutes for all three workflows, offset so they don't collide:
  `Buscar Ofertas ML` at :00/:30, `Buscar Ofertas Amazon` at :10/:40, `Selecionar e Postar` at
  :20/:50 (workflow timezone `America/Sao_Paulo`).
- Minimum discount to qualify: 20%.
- Max posts per `Selecionar e Postar` run: 5 (enforced by `LIMIT 5` in its query).
- Repost rule: only if `current_price < last_posted_price` for that `(platform, product_id)`.
- Mercado Livre discovery: `User-Agent: WhatsApp/2.23.20.0 A` (validated 2026-07-13 — bypasses the
  anti-bot block that blocks normal browser traffic on `lista.mercadolivre.com.br` and individual
  product pages).
- Amazon discovery: normal browser `User-Agent`, no special header needed (validated 2026-07-13).
- All 3 workflow JSON files live in `workflows/` in this repo and are the source of truth — edit
  them there and re-import, rather than hand-editing only inside the n8n UI.
- Never commit real credentials (Postgres password, Evolution API key, Amazon affiliate tag) —
  attached via n8n's credential UI / Config Set nodes, not stored in the workflow JSON.

---

### Task 1: Postgres Schema

**Files:**
- Already created: `sql/001_init_schema.sql`

**Interfaces:**
- Produces: tables `search_categories`, `deal_candidates`, `posted_deals`, columns exactly as
  documented in the design doc's data model section — every later task's Postgres nodes assume
  these exact names. `posted_deals` has a unique index on `(platform, product_id)` used for
  upsert in Task 4's "Registrar Postagem" node.

- [ ] **Step 1: Confirm the connection string**

Same Postgres instance as `price-monitor-n8n` (reuse `DATABASE_URL` if you still have it exported
from that project):

```bash
export DATABASE_URL="postgres://usuario:senha@localhost:5432/n8n"
```

- [ ] **Step 2: Apply the migration**

```bash
psql "$DATABASE_URL" -f sql/001_init_schema.sql
```

Expected: `CREATE TABLE` printed three times, no errors.

- [ ] **Step 3: Verify the schema**

```bash
psql "$DATABASE_URL" -c "\d search_categories" -c "\d deal_candidates" -c "\d posted_deals"
```

Expected: `search_categories` shows `id, keyword, platform, active, created_at`; `deal_candidates`
shows `id, platform, product_id, product_url, product_name, image_url, current_price,
original_price, discount_pct, coupon_code, found_at`; `posted_deals` shows `id, platform,
product_id, last_posted_price, last_posted_at` with a unique constraint on `(platform,
product_id)`.

- [ ] **Step 4: Seed a couple of test categories**

```bash
psql "$DATABASE_URL" -c "
INSERT INTO search_categories (keyword, platform) VALUES
  ('suplementos', 'both'),
  ('fone de ouvido', 'both');
"
```

Expected: `INSERT 0 2`.

- [ ] **Step 5: Round-trip test on `posted_deals` upsert (used later by Task 4)**

```bash
psql "$DATABASE_URL" -c "
INSERT INTO posted_deals (platform, product_id, last_posted_price)
VALUES ('ml', 'MLB_TEST', 100.00)
ON CONFLICT (platform, product_id)
DO UPDATE SET last_posted_price = EXCLUDED.last_posted_price;
"
psql "$DATABASE_URL" -c "
INSERT INTO posted_deals (platform, product_id, last_posted_price)
VALUES ('ml', 'MLB_TEST', 80.00)
ON CONFLICT (platform, product_id)
DO UPDATE SET last_posted_price = EXCLUDED.last_posted_price;
"
psql "$DATABASE_URL" -c "SELECT * FROM posted_deals WHERE product_id = 'MLB_TEST';"
```

Expected: one row, `last_posted_price = 80.00` (the second insert updated, didn't duplicate).
Clean up:

```bash
psql "$DATABASE_URL" -c "DELETE FROM posted_deals WHERE product_id = 'MLB_TEST';"
```

- [ ] **Step 6: Commit**

```bash
git add sql/001_init_schema.sql
git commit -m "Add Postgres schema for search_categories, deal_candidates, posted_deals"
```

---

### Task 2: Workflow "Buscar Ofertas ML"

**Files:**
- Already created: `workflows/buscar-ofertas-ml.json`

**Interfaces:**
- Consumes: `search_categories` rows where `platform IN ('ml','both') AND active = true`.
- Produces: rows in `deal_candidates` with `platform = 'ml'`, discount ≥ 20%. Every field
  populated: `product_id` (e.g. `MLB66637233`), `product_url`, `product_name`, `image_url`,
  `current_price`, `original_price`, `discount_pct`.
- Extraction logic (`Descobrir Ofertas ML` Code node) was validated 2026-07-13 against real
  captured HTML before being written — see this task's Step 4 for a live re-confirmation.

- [ ] **Step 1: Import the workflow**

Workflows → Import from File → `workflows/buscar-ofertas-ml.json`.

Expected: a workflow named "Buscar Ofertas ML" appears with 4 nodes: Agendamento, Buscar
Categorias Ativas, Descobrir Ofertas ML, Inserir Candidatos.

- [ ] **Step 2: Attach credentials**

Open "Buscar Categorias Ativas" and "Inserir Candidatos" (both Postgres nodes) and attach your
Postgres credential — if you already created one for `price-monitor-n8n` on this same n8n
instance, reuse it (no need to create a second one).

- [ ] **Step 3: Manual test**

Click "Test workflow". Expected:
- "Buscar Categorias Ativas" returns the 2 rows seeded in Task 1 (`suplementos`, `fone de
  ouvido`).
- "Descobrir Ofertas ML" runs (can take 30–90 seconds — it makes one listing request per keyword,
  plus one request per candidate found, sequentially). Open its output and confirm you get an
  array of items with `platform: "ml"`, non-null `current_price`, `original_price`, and
  `discount_pct >= 20`. **Zero results is a valid outcome** (depends on what's actually discounted
  right now on those keywords) — don't treat an empty array as a bug by itself.
- If items were found, "Inserir Candidatos" runs without SQL error.

- [ ] **Step 4: Verify the database side**

```bash
psql "$DATABASE_URL" -c "SELECT platform, product_id, product_name, current_price, original_price, discount_pct FROM deal_candidates WHERE platform = 'ml' ORDER BY found_at DESC LIMIT 5;"
```

Expected: rows matching what Step 3's execution showed (or zero rows, if Step 3 legitimately found
no qualifying deals — in that case, temporarily lower `MIN_DISCOUNT_PCT` to `1` in the "Descobrir
Ofertas ML" Code node, re-run, confirm you now get rows, then **set it back to `20`** and re-run
once more before moving on).

- [ ] **Step 5: Activate**

Toggle "Buscar Ofertas ML" to Active in n8n.

- [ ] **Step 6: Commit**

```bash
git add workflows/buscar-ofertas-ml.json
git commit -m "Add Mercado Livre deal-discovery workflow"
```

---

### Task 3: Workflow "Buscar Ofertas Amazon"

**Files:**
- Already created: `workflows/buscar-ofertas-amazon.json`

**Interfaces:**
- Consumes: `search_categories` rows where `platform IN ('amazon','both') AND active = true`.
- Produces: rows in `deal_candidates` with `platform = 'amazon'`, discount ≥ 20%. `product_id` is
  the ASIN (e.g. `B07939CW22`), `product_url` is the canonical `amazon.com.br/dp/{ASIN}` form.
- Extraction logic (`Descobrir Ofertas Amazon` Code node) was validated 2026-07-13 against real
  captured search-results HTML (found 3 qualifying deals out of 20 candidates checked on the
  "suplementos" keyword) before being written.

- [ ] **Step 1: Import the workflow**

Workflows → Import from File → `workflows/buscar-ofertas-amazon.json`.

Expected: a workflow named "Buscar Ofertas Amazon" appears with 4 nodes (same shape as Task 2).

- [ ] **Step 2: Attach credentials**

Same as Task 2 Step 2 — Postgres credential on "Buscar Categorias Ativas" and "Inserir
Candidatos".

- [ ] **Step 3: Manual test**

Click "Test workflow". Expected:
- "Buscar Categorias Ativas" returns the same 2 seeded rows (both have `platform = 'both'`, so
  they qualify here too).
- "Descobrir Ofertas Amazon" runs (faster than Task 2 — one request per keyword, no per-candidate
  follow-up). Confirm output items have `platform: "amazon"`, `product_id` looking like a 10-char
  ASIN, `discount_pct >= 20`.
- "Inserir Candidatos" runs without SQL error if any items were found.

- [ ] **Step 4: Verify the database side**

```bash
psql "$DATABASE_URL" -c "SELECT platform, product_id, product_name, current_price, original_price, discount_pct FROM deal_candidates WHERE platform = 'amazon' ORDER BY found_at DESC LIMIT 5;"
```

Expected: rows matching Step 3's output.

- [ ] **Step 5: Activate**

Toggle "Buscar Ofertas Amazon" to Active in n8n.

- [ ] **Step 6: Commit**

```bash
git add workflows/buscar-ofertas-amazon.json
git commit -m "Add Amazon deal-discovery workflow"
```

---

### Task 4: Investigar link de afiliado do Mercado Livre

**Files:**
- Modify (conditionally, see Step 4 below): `workflows/selecionar-e-postar.json`

**Interfaces:**
- Produces: either (a) a confirmed HTTP call the "Gerar Link e Mensagem" node in Task 5 can use to
  generate real ML affiliate links, or (b) a documented decision to leave ML posts without
  affiliate tracking for now. Either outcome unblocks Task 5 — don't skip this task, but don't
  block on it either if (b) is where you land.

- [ ] **Step 1: Open the Linkbuilder tool with DevTools ready**

In your browser, logged into your Mercado Livre account: open
`https://www.mercadolivre.com.br/afiliados/linkbuilder#hub`. Before doing anything else, open
DevTools (F12 or Cmd+Option+I), go to the **Network** tab, and filter by **Fetch/XHR**.

- [ ] **Step 2: Trigger the batch link generation**

Use the tool's batch/list mode (the option you confirmed exists — paste multiple URLs at once).
Paste 2–3 real product URLs (from Mercado Livre, any category) and submit.

- [ ] **Step 3: Inspect the network request**

In the Network tab, find the request that fired when you submitted (look for something with
"link", "affiliate", "shorten", or similar in the URL). Click it and note down:
- **Request URL** and **Method** (GET/POST)
- **Request Headers** — specifically any `Authorization`, `Cookie`, or custom `X-*` header
- **Request Payload/Body** (if POST) — the exact JSON shape sent
- **Response** — the exact JSON shape received, specifically where the generated link appears

- [ ] **Step 4: Decide and implement**

**If you found a clean, session-based API call** (a JSON request/response, even if it needs a
cookie): open `workflows/selecionar-e-postar.json` in the n8n UI, and:
1. Add an HTTP Request node named "Gerar Link Afiliado ML" between "SplitInBatches" and "Gerar
   Link e Mensagem" (only wired for the `platform === 'ml'` case — you can either add an IF node
   to branch, or call it unconditionally and ignore the result for Amazon items).
2. Configure it with the Request URL/Method/Body found in Step 3. For the auth header/cookie,
   create a new credential (Header Auth or Generic Credential) holding that value — do not
   hardcode it in the node.
3. Update "Gerar Link e Mensagem"'s `jsCode`: replace the `else { affiliateUrl = item.product_url;
   }` branch with `else { affiliateUrl = $json.ml_affiliate_url; }` (or whatever field name the
   new node outputs).
4. Test manually with one real ML product URL, confirm the response contains a working shortened
   link (paste it in a browser, confirm it redirects to the product).

**If there's no clean API** (e.g. the tool only works via full page interaction, CSRF-protected
forms, or similar): leave `workflows/selecionar-e-postar.json` as-is (ML posts go out with the
plain product URL, no affiliate credit, for now). Note this explicitly in
`README.md` under "Pendência" so it's not forgotten, and move on to Task 5 — Amazon affiliate
links already work independently of this.

- [ ] **Step 5: Commit**

```bash
git add workflows/selecionar-e-postar.json README.md
git commit -m "Resolve Mercado Livre affiliate link investigation" --allow-empty
```

(`--allow-empty` covers the case where you took the "no clean API" branch and only changed
`README.md`, or nothing at all.)

---

### Task 5: Workflow "Selecionar e Postar"

**Files:**
- Already created: `workflows/selecionar-e-postar.json` (possibly modified by Task 4)

**Interfaces:**
- Consumes: `deal_candidates` rows from the last 35 minutes, `posted_deals` for dedup.
- Produces: WhatsApp messages (image + caption) via Evolution API `sendMedia`; upserts into
  `posted_deals`.

- [ ] **Step 1: Create the WhatsApp destination group**

Create a new WhatsApp group (separate from the `price-monitor-n8n` one — this is a content/promo
group, not a personal assistant). Add the bot's number to it. Find its JID:

```bash
curl -s -H "apikey: SUA_API_KEY" "http://localhost:8080/group/fetchAllGroups/SUA_INSTANCIA?getParticipants=false"
```

Note the `id` field (format `<numbers>@g.us`) for the group you just created.

- [ ] **Step 2: Import the workflow**

Workflows → Import from File → `workflows/selecionar-e-postar.json`.

Expected: a workflow named "Selecionar e Postar" appears with 9 nodes: Agendamento, Config, Buscar
Melhores Candidatos, SplitInBatches, Gerar Link e Mensagem, Postar no Grupo, Registrar Postagem,
Limit, Fim.

- [ ] **Step 3: Attach credentials**

- "Buscar Melhores Candidatos" e "Registrar Postagem" (Postgres nodes) → your Postgres credential.
- "Postar no Grupo" (HTTP Request node) → your existing "Evolution API" Header Auth credential
  (same one used in `price-monitor-n8n`, if you have it on this instance).

- [ ] **Step 4: Fill in the Config node**

Open the "Config" node and replace:
- `evolutionApiUrl` → your real Evolution API base URL
- `evolutionInstance` → your real instance name
- `groupJid` → the JID from Step 1
- `amazonAffiliateTag` → your real Amazon Associates tag (e.g. `seunome-20`)

- [ ] **Step 5: Force a test candidate through the pipeline**

Insert a fake but realistic candidate directly, so you can test the full pipeline without waiting
for real discovery + without spamming the group with something you can't control the content of:

```bash
psql "$DATABASE_URL" -c "
INSERT INTO deal_candidates (platform, product_id, product_url, product_name, image_url, current_price, original_price, discount_pct)
VALUES ('amazon', 'TESTE123', 'https://www.amazon.com.br/dp/TESTE123', 'Produto de Teste do Plano', 'https://http2.mlstatic.com/D_NQ_NP_2X_871404-MLB101915749897_122025-T-kit-c-3-camisetas-tommy-hilfiger-masculina-essential-cotton.webp', 49.90, 99.90, 50.0);
"
```

- [ ] **Step 6: Run "Selecionar e Postar" manually**

Click "Test workflow". Expected:
- "Buscar Melhores Candidatos" returns your test row (and possibly real ones from Tasks 2/3 if
  they ran recently and found qualifying deals).
- "Gerar Link e Mensagem" output for the test row shows `affiliate_url` ending in
  `?tag=<sua_tag>` and a `caption` field formatted per the design doc's message template.
- "Postar no Grupo" succeeds (check your WhatsApp group — you should see the test message with
  the Tommy Hilfiger t-shirt image and "Produto de Teste do Plano" caption).
- "Registrar Postagem" runs without SQL error.

- [ ] **Step 7: Verify dedup works**

Run "Test workflow" a second time immediately. Expected: `posted_deals` now has a row for
`('amazon', 'TESTE123')` with `last_posted_price = 49.90`, so "Buscar Melhores Candidatos" should
**not** return that row again (the `dc.current_price < pd.last_posted_price` condition fails since
they're equal) — confirm no duplicate message arrives in the group.

Then confirm a genuine price drop re-triggers it:

```bash
psql "$DATABASE_URL" -c "UPDATE deal_candidates SET current_price = 39.90, found_at = now() WHERE product_id = 'TESTE123';"
```

Run "Test workflow" again. Expected: the test message posts again (price dropped from 49.90 to
39.90), and `posted_deals.last_posted_price` updates to `39.90`.

- [ ] **Step 8: Clean up test data**

```bash
psql "$DATABASE_URL" -c "DELETE FROM deal_candidates WHERE product_id = 'TESTE123';"
psql "$DATABASE_URL" -c "DELETE FROM posted_deals WHERE product_id = 'TESTE123';"
```

- [ ] **Step 9: Activate**

Toggle "Selecionar e Postar" to Active in n8n.

- [ ] **Step 10: Commit**

```bash
git add workflows/selecionar-e-postar.json
git commit -m "Add deal selection and WhatsApp posting workflow"
```

---

### Task 6: Go Live

**Files:**
- Modify: any workflow JSON files touched during live testing (re-export and overwrite so the
  repo matches what's deployed)

- [ ] **Step 1: Confirm all three workflows are Active**

In n8n, check "Buscar Ofertas ML", "Buscar Ofertas Amazon", and "Selecionar e Postar" all show the
Active toggle on.

- [ ] **Step 2: Adjust your search categories to real interests**

```bash
psql "$DATABASE_URL" -c "SELECT * FROM search_categories;"
```

Remove or deactivate the test ones from Task 1 if they don't reflect what you actually want, and
add the real categories you care about:

```bash
psql "$DATABASE_URL" -c "
UPDATE search_categories SET active = false WHERE keyword IN ('suplementos', 'fone de ouvido');
INSERT INTO search_categories (keyword, platform) VALUES
  ('SUA_CATEGORIA_1', 'both'),
  ('SUA_CATEGORIA_2', 'both');
"
```

(Keep `suplementos`/`fone de ouvido` active too if they're genuinely categories you want — this
step is just making sure the list reflects real intent, not leftover test data.)

- [ ] **Step 3: Watch the first full real cycle**

Wait for one full 30-minute cycle (all three crons firing in sequence: :00 ML, :10 Amazon, :20
Selecionar e Postar, or the next half-hour equivalent). In n8n, check the **Executions** tab for
all three workflows — confirm no red (failed) executions, and check your WhatsApp group for any
real posts that came through.

- [ ] **Step 4: Sync any node edits back to the repo**

If you had to adjust any Code node's regex or logic during live testing (e.g. Mercado Livre or
Amazon changed their page structure since 2026-07-13), re-export the affected workflow from n8n
(⋮ menu → Download) and overwrite the corresponding file in `workflows/`.

```bash
git add workflows/
git commit -m "Sync workflow edits made during live testing" --allow-empty
```

- [ ] **Step 5: Final commit**

```bash
git add -A
git commit -m "Promo poster bot: schema, workflows, and docs ready for production" --allow-empty
git log --oneline
```

Expected: a clean commit history covering schema, both discovery workflows, the affiliate
investigation, the posting workflow, and docs.
