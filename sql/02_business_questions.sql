/* ============================================================
   UrbanCart E-Commerce Analytics — Business Question Queries
   Organized by stakeholder. Every number in the final report
   and dashboard is traceable back to one of these queries.
   ============================================================ */


/* ============================================================
   STAKEHOLDER 1: Sarah Chen — Chief Executive Officer
   Q: What is our overall revenue trend across 2023-2024
      (by month, country, and customer segment), and who are
      our best customers by revenue and order frequency?
   ============================================================ */

-- Q1a. Revenue trend by month / country / segment, with MoM growth
WITH monthly_revenue AS (
    SELECT
        FORMAT(o.order_date, 'yyyy-MM') AS order_month,
        c.country,
        c.customer_segment,
        SUM(o.order_total)              AS revenue,
        COUNT(DISTINCT o.order_id)      AS order_count
    FROM vw_fact_orders o
    JOIN vw_dim_customers c ON o.customer_id = c.customer_id
    WHERE o.order_status <> 'Cancelled'
    GROUP BY FORMAT(o.order_date, 'yyyy-MM'), c.country, c.customer_segment
)
SELECT
    order_month, country, customer_segment, revenue, order_count,
    LAG(revenue) OVER (PARTITION BY country, customer_segment ORDER BY order_month) AS prev_month_revenue,
    ROUND(100.0 * (revenue - LAG(revenue) OVER (PARTITION BY country, customer_segment ORDER BY order_month))
        / NULLIF(LAG(revenue) OVER (PARTITION BY country, customer_segment ORDER BY order_month), 0), 1) AS mom_growth_pct
FROM monthly_revenue
ORDER BY country, customer_segment, order_month;

-- Q1b. Headline YoY check
SELECT YEAR(order_date) AS order_year, SUM(order_total) AS total_revenue, COUNT(DISTINCT order_id) AS total_orders
FROM vw_fact_orders
WHERE order_status <> 'Cancelled'
GROUP BY YEAR(order_date)
ORDER BY order_year;
-- RESULT: 2023 = $9,694,412.07 | 2024 = $9,741,291.44  ->  +0.48% YoY

-- Q1c. Best customers by revenue and order frequency
WITH customer_metrics AS (
    SELECT
        c.customer_id, c.first_name, c.last_name, c.country, c.customer_segment,
        SUM(o.order_total) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS order_count,
        AVG(o.order_total) AS avg_order_value
    FROM vw_dim_customers c
    JOIN vw_fact_orders o ON c.customer_id = o.customer_id
    WHERE o.order_status <> 'Cancelled'
    GROUP BY c.customer_id, c.first_name, c.last_name, c.country, c.customer_segment
)
SELECT *,
    RANK() OVER (ORDER BY total_revenue DESC) AS revenue_rank,
    RANK() OVER (ORDER BY order_count DESC)   AS frequency_rank,
    NTILE(10) OVER (ORDER BY total_revenue DESC) AS revenue_decile
FROM customer_metrics
WHERE NTILE(10) OVER (ORDER BY total_revenue DESC) = 1
ORDER BY total_revenue DESC;

-- Q1d. Pareto concentration check
WITH customer_revenue AS (
    SELECT customer_id, SUM(order_total) AS total_revenue
    FROM vw_fact_orders WHERE order_status <> 'Cancelled'
    GROUP BY customer_id
),
ranked AS (
    SELECT customer_id, total_revenue,
        SUM(total_revenue) OVER (ORDER BY total_revenue DESC) / SUM(total_revenue) OVER () AS cumulative_pct_revenue
    FROM customer_revenue
)
SELECT ROUND(100.0 * COUNT(CASE WHEN cumulative_pct_revenue <= 0.80 THEN 1 END) / COUNT(*), 1) AS pct_customers_driving_80pct_revenue
FROM ranked;
-- RESULT: 44.5% of customers drive 80% of revenue (vs. healthy ~20% benchmark)


/* ============================================================
   STAKEHOLDER 2: Marcus Lee — VP of Marketing
   Q: Which acquisition channels bring in the most customers and
      the most valuable customers, and how do website traffic
      patterns line up with order volume?
   ============================================================ */

-- Q2a. Customers and value by channel
WITH channel_customers AS (
    SELECT ch.channel,
        COUNT(DISTINCT c.customer_id) AS customer_count,
        SUM(o.order_total) AS total_revenue,
        COUNT(DISTINCT o.order_id) AS total_orders
    FROM vw_dim_customers c
    JOIN vw_dim_channel ch ON c.acquisition_channel_key = ch.channel_key
    LEFT JOIN vw_fact_orders o ON c.customer_id = o.customer_id AND o.order_status <> 'Cancelled'
    GROUP BY ch.channel
)
SELECT *,
    ROUND(total_revenue * 1.0 / NULLIF(customer_count, 0), 2) AS revenue_per_customer,
    RANK() OVER (ORDER BY customer_count DESC) AS acquisition_rank,
    RANK() OVER (ORDER BY total_revenue DESC)  AS value_rank
FROM channel_customers
ORDER BY total_revenue DESC;

-- Q2b. Traffic patterns by channel and device
WITH Traffic_Metrics AS (
    SELECT channel_key, device,
        SUM(CAST(sessions AS BIGINT)) AS total_sessions,
        AVG(bounce_rate) AS avg_bounce_rate,
        AVG(avg_session_duration_sec) AS avg_session_duration
    FROM vw_fact_website_traffic
    GROUP BY channel_key, device
),
Order_Metrics AS (
    SELECT c.acquisition_channel_key, COUNT(DISTINCT o.order_id) AS orders_from_channel
    FROM vw_dim_customers c
    JOIN vw_fact_orders o ON c.customer_id = o.customer_id AND o.order_status <> 'Cancelled'
    GROUP BY c.acquisition_channel_key
)
SELECT ch.channel, tm.device, tm.total_sessions, tm.avg_bounce_rate, tm.avg_session_duration,
    ISNULL(om.orders_from_channel, 0) AS orders_from_channel
FROM vw_dim_channel ch
JOIN Traffic_Metrics tm ON ch.channel_key = tm.channel_key
LEFT JOIN Order_Metrics om ON ch.channel_key = om.acquisition_channel_key
ORDER BY tm.total_sessions DESC;

-- Q2c. Marketing efficiency — CAC and ROAS by channel
WITH campaign_spend AS (
    SELECT ch.channel, SUM(mc.budget_usd) AS total_spend
    FROM vw_fact_marketing_campaigns mc
    JOIN vw_dim_channel ch ON mc.channel_key = ch.channel_key
    GROUP BY ch.channel
),
channel_results AS (
    SELECT ch.channel,
        COUNT(DISTINCT c.customer_id) AS customers_acquired,
        SUM(o.order_total) AS revenue
    FROM vw_dim_customers c
    JOIN vw_dim_channel ch ON c.acquisition_channel_key = ch.channel_key
    LEFT JOIN vw_fact_orders o ON c.customer_id = o.customer_id AND o.order_status <> 'Cancelled'
    GROUP BY ch.channel
)
SELECT r.channel, s.total_spend, r.customers_acquired, r.revenue,
    ROUND(s.total_spend * 1.0 / NULLIF(r.customers_acquired, 0), 2) AS cac,
    ROUND(r.revenue * 1.0 / NULLIF(s.total_spend, 0), 2) AS roas
FROM channel_results r
LEFT JOIN campaign_spend s ON r.channel = s.channel
ORDER BY roas DESC;
-- KEY RESULT: Paid Search ROAS 8.82x (CAC $276.88) beats Social Media ROAS 6.69x (CAC $338.19)
-- Direct shows 28.6x ROAS on $98K spend — flagged as likely brand/awareness spend, not
-- directly attributable; excluded from budget-reallocation decisions without further attribution work.


/* ============================================================
   STAKEHOLDER 3: Priya Anand — Head of Merchandising
   Q: Which product categories/products drive the most revenue
      and profit, and how much profit is eaten by discounts?
   ============================================================ */

-- Q3a. Category-level revenue, profit, margin
SELECT
    p.category,
    SUM(oi.line_total) AS revenue,
    SUM(oi.line_total) - SUM(oi.quantity * p.cost_price) AS gross_profit,
    ROUND(100.0 * (SUM(oi.line_total) - SUM(oi.quantity * p.cost_price)) / NULLIF(SUM(oi.line_total), 0), 1) AS margin_pct,
    SUM(oi.quantity) AS units_sold
FROM vw_fact_order_items oi
JOIN vw_dim_products p ON oi.product_id = p.product_id
JOIN vw_fact_orders o ON oi.order_id = o.order_id
WHERE o.order_status NOT IN ('Cancelled', 'Returned')
GROUP BY p.category
ORDER BY gross_profit DESC;
-- KEY RESULT: Electronics = $7.82M revenue / 28.7% margin (weakest)
--             Beauty & Personal Care = $0.80M revenue / 58.4% margin (strongest)

-- Q3b. Product-level revenue/profit rank gap ("busy but not profitable" finder)
SELECT TOP 20 category, product_name, revenue, margin_pct, revenue_rank, profit_rank,
    (revenue_rank - profit_rank) AS rank_gap
FROM (
    SELECT p.category, p.product_name,
        SUM(oi.line_total) AS revenue,
        ROUND(100.0 * (SUM(oi.line_total) - SUM(oi.quantity * p.cost_price)) / NULLIF(SUM(oi.line_total), 0), 1) AS margin_pct,
        RANK() OVER (ORDER BY SUM(oi.line_total) DESC) AS revenue_rank,
        RANK() OVER (ORDER BY SUM(oi.line_total) - SUM(oi.quantity * p.cost_price) DESC) AS profit_rank
    FROM vw_fact_order_items oi
    JOIN vw_dim_products p ON oi.product_id = p.product_id
    JOIN vw_fact_orders o ON oi.order_id = o.order_id
    WHERE o.order_status NOT IN ('Cancelled', 'Returned')
    GROUP BY p.category, p.product_name
) x
ORDER BY rank_gap DESC;

-- Q3c. Discount erosion by category
SELECT p.category,
    SUM(oi.line_total) AS net_revenue,
    SUM(oi.quantity * p.list_price) AS gross_revenue_before_discount,
    SUM(oi.quantity * p.list_price) - SUM(oi.line_total) AS discount_amount,
    ROUND(100.0 * (SUM(oi.quantity * p.list_price) - SUM(oi.line_total)) / NULLIF(SUM(oi.quantity * p.list_price), 0), 1) AS discount_pct_of_gross
FROM vw_fact_order_items oi
JOIN vw_dim_products p ON oi.product_id = p.product_id
JOIN vw_fact_orders o ON oi.order_id = o.order_id
WHERE o.order_status NOT IN ('Cancelled', 'Returned')
GROUP BY p.category
ORDER BY discount_amount DESC;
-- KEY RESULT: discount rate is flat (~8-10%) across every category -> rules out
-- over-discounting as the cause of Electronics' weak margin; it's a cost-structure issue.

-- Q3d. Coupon usage impact on order value
SELECT
    CASE WHEN coupon_code = 'No Coupon' OR coupon_code IS NULL THEN 'No Coupon' ELSE 'Coupon Used' END AS coupon_flag,
    COUNT(DISTINCT order_id) AS order_count,
    SUM(order_total) AS revenue,
    AVG(order_total) AS avg_order_value
FROM vw_fact_orders
WHERE order_status NOT IN ('Cancelled', 'Returned')
GROUP BY CASE WHEN coupon_code = 'No Coupon' OR coupon_code IS NULL THEN 'No Coupon' ELSE 'Coupon Used' END;
-- RESULT: Coupon orders AOV $803.09 vs No-Coupon AOV $936.72  (-14%)


/* ============================================================
   STAKEHOLDER 4: Daniel Osei — Director of Customer Experience
   Q: How does delivery performance relate to satisfaction and
      ticket volume, and what is our cancellation/return trend?
   ============================================================ */

-- Q4a. Delivery bucket vs ticket rate & satisfaction
WITH delivery_buckets AS (
    SELECT order_id, delivery_days,
        CASE WHEN delivery_days <= 2 THEN '0-2 days'
             WHEN delivery_days <= 4 THEN '3-4 days'
             WHEN delivery_days <= 7 THEN '5-7 days'
             WHEN delivery_days <= 10 THEN '8-10 days'
             ELSE '11+ days' END AS delivery_bucket
    FROM vw_fact_orders
    WHERE order_status = 'Delivered'
)
SELECT db.delivery_bucket,
    COUNT(DISTINCT db.order_id) AS orders_in_bucket,
    COUNT(DISTINCT st.ticket_id) AS tickets_in_bucket,
    ROUND(100.0 * COUNT(DISTINCT st.ticket_id) / NULLIF(COUNT(DISTINCT db.order_id), 0), 1) AS ticket_rate_pct,
    ROUND(AVG(st.satisfaction_score), 2) AS avg_satisfaction
FROM delivery_buckets db
LEFT JOIN vw_fact_support_tickets st ON db.order_id = st.order_id
GROUP BY db.delivery_bucket
ORDER BY CASE db.delivery_bucket
    WHEN '0-2 days' THEN 1 WHEN '3-4 days' THEN 2 WHEN '5-7 days' THEN 3
    WHEN '8-10 days' THEN 4 ELSE 5 END;
-- KEY RESULT: ticket rate stays flat 8-13% regardless of delivery speed ->
-- delivery is NOT the driver of support volume, contrary to the stakeholder's hypothesis.

-- Q4b. Ticket volume and satisfaction by issue type
SELECT issue_type, COUNT(*) AS ticket_count,
    AVG(satisfaction_score) AS avg_satisfaction,
    AVG(DATEDIFF(day, opened_date, resolved_date)) AS avg_resolution_days
FROM vw_fact_support_tickets
GROUP BY issue_type
ORDER BY ticket_count DESC;
-- KEY RESULT: Payment Issue (2.96) and Account Issue (3.01) are the LOWEST
-- satisfaction categories -- not Late Delivery (3.05) as the stakeholder assumed.

-- Q4c. Monthly cancellation/return rate trend
WITH monthly_status AS (
    SELECT FORMAT(order_date, 'yyyy-MM') AS order_month,
        COUNT(*) AS total_orders,
        SUM(CASE WHEN order_status = 'Cancelled' THEN 1 ELSE 0 END) AS cancelled_orders,
        SUM(CASE WHEN order_status = 'Returned' THEN 1 ELSE 0 END) AS returned_orders
    FROM vw_fact_orders
    GROUP BY FORMAT(order_date, 'yyyy-MM')
)
SELECT order_month, total_orders, cancelled_orders, returned_orders,
    ROUND(100.0 * cancelled_orders / total_orders, 2) AS cancellation_rate_pct,
    ROUND(100.0 * returned_orders / total_orders, 2) AS return_rate_pct
FROM monthly_status
ORDER BY order_month;
-- KEY RESULT: no secular up/down trend -- Nov/Dec spikes are seasonal volume,
-- not degrading service quality.

-- Q4d. Overall headline cancellation + return rate
SELECT COUNT(*) AS total_orders,
    SUM(CASE WHEN order_status IN ('Cancelled','Returned') THEN 1 ELSE 0 END) AS cancelled_or_returned,
    ROUND(100.0 * SUM(CASE WHEN order_status IN ('Cancelled','Returned') THEN 1 ELSE 0 END) / COUNT(*), 2) AS overall_rate_pct
FROM vw_fact_orders;
-- RESULT: 19.3% combined cancellation + return rate
