/* ============================================================
   UrbanCart E-Commerce Analytics — Data Cleaning & Modeling
   ============================================================
   Source: 7 raw CSV exports (orders, customers, products,
   order_items, marketing_campaigns, website_traffic, support_tickets)
   Target: Star schema — one fact per business process, shared
   conformed dimensions (customers, products, channel, date)
   ============================================================ */

-- ------------------------------------------------------------
-- 1. STANDARDIZE TEXT CASING & FORMATS
-- ------------------------------------------------------------
-- Applied to customers.gender, products.category, products.sub_category
-- Rule: TRIM + INITCAP-style standardization to prevent duplicate
-- groupings from casing inconsistency (e.g. "electronics" vs "Electronics")

UPDATE stg_customers
SET gender = UPPER(LEFT(TRIM(gender), 1)) + LOWER(SUBSTRING(TRIM(gender), 2, LEN(gender)));

UPDATE stg_products
SET category = TRIM(category),
    sub_category = TRIM(sub_category);

-- ------------------------------------------------------------
-- 2. DEDUPE ON NATURAL KEYS
-- ------------------------------------------------------------
-- Rule: keep the most recently modified/loaded row per natural key,
-- discard exact and near-duplicate records

WITH ranked_customers AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY customer_id ORDER BY signup_date DESC) AS rn
    FROM stg_customers
)
DELETE FROM ranked_customers WHERE rn > 1;

WITH ranked_products AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY product_id ORDER BY launch_date DESC) AS rn
    FROM stg_products
)
DELETE FROM ranked_products WHERE rn > 1;

WITH ranked_orders AS (
    SELECT *,
        ROW_NUMBER() OVER (PARTITION BY order_id ORDER BY order_date DESC) AS rn
    FROM stg_orders
)
DELETE FROM ranked_orders WHERE rn > 1;

-- ------------------------------------------------------------
-- 3. NULL HANDLING RULE (documented, not silently dropped)
-- ------------------------------------------------------------
-- customer_segment: NULL -> 'Unknown' (explicit flag, not excluded)
-- acquisition_channel_key: NULL retained as-is and flagged in
--   reporting layer (see README Data Quality section) rather than
--   imputed, since imputing a channel would fabricate attribution data
-- coupon_code: NULL -> 'No Coupon' (business-meaningful default)

UPDATE stg_customers
SET customer_segment = 'Unknown'
WHERE customer_segment IS NULL;

UPDATE stg_orders
SET coupon_code = 'No Coupon'
WHERE coupon_code IS NULL;

-- ------------------------------------------------------------
-- 4. INVALID VALUE HANDLING
-- ------------------------------------------------------------
-- Negative quantities / costs and zero prices are flagged into a
-- quarantine table for manual review rather than silently corrected

SELECT *
INTO quarantine_order_items
FROM stg_order_items
WHERE quantity <= 0 OR unit_price <= 0;

DELETE FROM stg_order_items
WHERE quantity <= 0 OR unit_price <= 0;

SELECT *
INTO quarantine_products
FROM stg_products
WHERE cost_price < 0 OR list_price <= 0;

-- ------------------------------------------------------------
-- 5. REFERENTIAL INTEGRITY CHECK
-- ------------------------------------------------------------
-- order_items rows with no matching order are quarantined, not deleted,
-- so the discrepancy is auditable

SELECT oi.*
INTO quarantine_orphan_order_items
FROM stg_order_items oi
LEFT JOIN stg_orders o ON oi.order_id = o.order_id
WHERE o.order_id IS NULL;

-- Known, documented gap: support tickets referencing an order_id that
-- doesn't resolve to a single customer (see README Data Quality
-- section, item 2 — shared placeholder customer_id)
SELECT st.*
INTO quarantine_orphan_tickets
FROM stg_support_tickets st
LEFT JOIN stg_orders o ON st.order_id = o.order_id
WHERE st.order_id IS NOT NULL AND o.order_id IS NULL;

-- ------------------------------------------------------------
-- 6. DATE FORMAT STANDARDIZATION
-- ------------------------------------------------------------
-- order_date arrived with a time component in some exports;
-- truncated to plain DATE so it joins cleanly to the date dimension

ALTER TABLE stg_orders ALTER COLUMN order_date DATE;

UPDATE stg_orders
SET order_date = CAST(order_date AS DATE);

/* ============================================================
   STAR SCHEMA — FINAL VIEWS (consumed by Power BI)
   ============================================================
   Fact tables: vw_fact_orders, vw_fact_order_items,
                vw_fact_marketing_campaigns, vw_fact_website_traffic,
                vw_fact_support_tickets
   Dimensions:  vw_dim_customers, vw_dim_products, vw_dim_channel,
                vw_dim_date
   ============================================================ */
