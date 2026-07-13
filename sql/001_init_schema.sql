CREATE TABLE search_categories (
    id SERIAL PRIMARY KEY,
    keyword TEXT NOT NULL,
    platform TEXT NOT NULL CHECK (platform IN ('ml', 'amazon', 'both')),
    active BOOLEAN NOT NULL DEFAULT true,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE deal_candidates (
    id SERIAL PRIMARY KEY,
    platform TEXT NOT NULL CHECK (platform IN ('ml', 'amazon')),
    product_id TEXT NOT NULL,
    product_url TEXT NOT NULL,
    product_name TEXT NOT NULL,
    image_url TEXT,
    current_price NUMERIC NOT NULL,
    original_price NUMERIC,
    discount_pct NUMERIC NOT NULL,
    coupon_code TEXT,
    found_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE posted_deals (
    id SERIAL PRIMARY KEY,
    platform TEXT NOT NULL,
    product_id TEXT NOT NULL,
    last_posted_price NUMERIC NOT NULL,
    last_posted_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (platform, product_id)
);
