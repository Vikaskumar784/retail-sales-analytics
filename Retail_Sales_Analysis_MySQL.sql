/* =========================================================================
   RETAIL SALES & BUSINESS PERFORMANCE ANALYTICS
   SQL Analysis — MySQL 8.0 compatible version

   Two tables:
     orders     - fact table, one row per order line  (from Raw_Data.csv)
     customers  - dimension table, one row per customer (from Customers.csv)
                  includes home_region so we can compare it against the
                  region an order actually shipped to
   ========================================================================= */

-- -------------------------------------------------------------------------
-- 0. SCHEMA
-- -------------------------------------------------------------------------
DROP TABLE IF EXISTS orders;
DROP TABLE IF EXISTS customers;

CREATE TABLE customers (
    customer_id    VARCHAR(10) PRIMARY KEY,
    customer_name  VARCHAR(100) NOT NULL,
    home_region    VARCHAR(20) NOT NULL
);

CREATE TABLE orders (
    order_id       VARCHAR(12) PRIMARY KEY,
    order_date     DATE NOT NULL,
    customer_id    VARCHAR(10) NOT NULL,
    category       VARCHAR(30) NOT NULL,
    product        VARCHAR(50) NOT NULL,
    region         VARCHAR(20) NOT NULL,      -- shipping region for this order
    city           VARCHAR(30) NOT NULL,
    quantity       INT NOT NULL,
    sales          NUMERIC(12,2) NOT NULL,
    discount_pct   NUMERIC(5,2) NOT NULL,     -- stored as e.g. 10.00 = 10%
    profit         NUMERIC(12,2) NOT NULL,
    shipping_mode  VARCHAR(20) NOT NULL,
    payment_mode   VARCHAR(20) NOT NULL,
    CONSTRAINT fk_customer FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- Load data in MySQL Workbench:
-- Right-click "customers" table in the schema panel > Table Data Import Wizard
-- > select Customers.csv. Repeat for "orders" > Retail_Sales_Raw_Data.csv.
-- (If you use LOAD DATA INFILE instead, make sure secure_file_priv allows it.)


-- -------------------------------------------------------------------------
-- Q1. Overall KPIs — total sales, profit, orders, margin
-- -------------------------------------------------------------------------
SELECT
    COUNT(*)                              AS total_orders,
    SUM(sales)                            AS total_sales,
    SUM(profit)                           AS total_profit,
    ROUND(SUM(profit) / SUM(sales), 4)    AS overall_profit_margin,
    ROUND(AVG(sales), 2)                  AS avg_order_value
FROM orders;


-- -------------------------------------------------------------------------
-- Q2. Monthly sales & profit trend
-- -------------------------------------------------------------------------
SELECT
    DATE_FORMAT(order_date, '%Y-%m')      AS order_month,
    SUM(sales)                            AS total_sales,
    SUM(profit)                           AS total_profit,
    COUNT(*)                              AS order_count
FROM orders
GROUP BY DATE_FORMAT(order_date, '%Y-%m')
ORDER BY order_month;


-- -------------------------------------------------------------------------
-- Q3. Region-wise performance, ranked by profit
-- -------------------------------------------------------------------------
SELECT
    region,
    SUM(sales)                                        AS total_sales,
    SUM(profit)                                        AS total_profit,
    ROUND(SUM(profit) / SUM(sales), 4)                 AS profit_margin,
    RANK() OVER (ORDER BY SUM(profit) DESC)            AS profit_rank
FROM orders
GROUP BY region
ORDER BY profit_rank;


-- -------------------------------------------------------------------------
-- Q4. Category performance with profit margin
-- -------------------------------------------------------------------------
SELECT
    category,
    SUM(sales)                            AS total_sales,
    SUM(profit)                           AS total_profit,
    ROUND(AVG(discount_pct), 2)           AS avg_discount_pct,
    ROUND(SUM(profit) / SUM(sales), 4)    AS profit_margin
FROM orders
GROUP BY category
ORDER BY total_profit DESC;


-- -------------------------------------------------------------------------
-- Q5. Top 10 customers by lifetime profit  (JOIN + aggregation)
-- -------------------------------------------------------------------------
SELECT
    c.customer_id,
    c.customer_name,
    c.home_region,
    COUNT(o.order_id)      AS order_count,
    SUM(o.sales)            AS total_sales,
    SUM(o.profit)            AS total_profit
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
GROUP BY c.customer_id, c.customer_name, c.home_region
ORDER BY total_profit DESC
LIMIT 10;


-- -------------------------------------------------------------------------
-- Q6. Customers who ordered OUTSIDE their home region
--     (JOIN comparing dimension attribute vs fact attribute)
-- -------------------------------------------------------------------------
SELECT
    c.customer_id,
    c.customer_name,
    c.home_region,
    o.region        AS shipped_to_region,
    COUNT(*)         AS out_of_region_orders,
    SUM(o.sales)     AS out_of_region_sales
FROM orders o
JOIN customers c ON c.customer_id = o.customer_id
WHERE o.region <> c.home_region
GROUP BY c.customer_id, c.customer_name, c.home_region, o.region
ORDER BY out_of_region_sales DESC;


-- -------------------------------------------------------------------------
-- Q7. Month-over-month sales growth %  (window function: LAG)
-- -------------------------------------------------------------------------
WITH monthly_sales AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m')  AS order_month,
        SUM(sales)                        AS total_sales
    FROM orders
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
)
SELECT
    order_month,
    total_sales,
    LAG(total_sales) OVER (ORDER BY order_month)            AS prev_month_sales,
    ROUND(
        (total_sales - LAG(total_sales) OVER (ORDER BY order_month))
        / NULLIF(LAG(total_sales) OVER (ORDER BY order_month), 0) * 100, 2
    )                                                        AS mom_growth_pct
FROM monthly_sales
ORDER BY order_month;


-- -------------------------------------------------------------------------
-- Q8. Running (cumulative) profit by month  (window function: SUM OVER)
-- -------------------------------------------------------------------------
WITH monthly_profit AS (
    SELECT
        DATE_FORMAT(order_date, '%Y-%m')  AS order_month,
        SUM(profit)                       AS total_profit
    FROM orders
    GROUP BY DATE_FORMAT(order_date, '%Y-%m')
)
SELECT
    order_month,
    total_profit,
    SUM(total_profit) OVER (ORDER BY order_month
                             ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS cumulative_profit
FROM monthly_profit
ORDER BY order_month;


-- -------------------------------------------------------------------------
-- Q9. Best-selling product per category  (window function: ROW_NUMBER)
-- -------------------------------------------------------------------------
WITH product_sales AS (
    SELECT
        category,
        product,
        SUM(sales)  AS total_sales,
        SUM(profit) AS total_profit,
        ROW_NUMBER() OVER (PARTITION BY category ORDER BY SUM(sales) DESC) AS rn
    FROM orders
    GROUP BY category, product
)
SELECT category, product, total_sales, total_profit
FROM product_sales
WHERE rn = 1
ORDER BY total_sales DESC;


-- -------------------------------------------------------------------------
-- Q10. Orders with above-average profit margin for their category
--      (correlated subquery)
-- -------------------------------------------------------------------------
SELECT
    o.order_id, o.category, o.product, o.sales, o.profit,
    ROUND(o.profit / NULLIF(o.sales, 0), 4) AS order_margin
FROM orders o
WHERE (o.profit / NULLIF(o.sales, 0)) > (
    SELECT AVG(o2.profit / NULLIF(o2.sales, 0))
    FROM orders o2
    WHERE o2.category = o.category
)
ORDER BY o.category, order_margin DESC;


-- -------------------------------------------------------------------------
-- Q11. Repeat customers vs one-time customers, and their revenue share
--      (CTE + CASE)
-- -------------------------------------------------------------------------
WITH customer_orders AS (
    SELECT customer_id, COUNT(*) AS order_count, SUM(sales) AS total_sales
    FROM orders
    GROUP BY customer_id
),
customer_type AS (
    SELECT
        customer_id,
        total_sales,
        CASE WHEN order_count > 1 THEN 'Repeat' ELSE 'One-Time' END AS customer_type
    FROM customer_orders
)
SELECT
    customer_type,
    COUNT(*)                                             AS customer_count,
    SUM(total_sales)                                     AS total_sales,
    ROUND(100.0 * SUM(total_sales) / SUM(SUM(total_sales)) OVER (), 2) AS pct_of_total_sales
FROM customer_type
GROUP BY customer_type;


-- -------------------------------------------------------------------------
-- Q12. Discount impact — does higher discount correlate with lower margin?
--      (bucketed aggregation)
-- -------------------------------------------------------------------------
SELECT
    CASE
        WHEN discount_pct = 0              THEN '0%'
        WHEN discount_pct <= 10            THEN '1-10%'
        WHEN discount_pct <= 20            THEN '11-20%'
        ELSE '21%+'
    END                                    AS discount_band,
    COUNT(*)                               AS order_count,
    SUM(sales)                             AS total_sales,
    SUM(profit)                            AS total_profit,
    ROUND(SUM(profit) / SUM(sales), 4)     AS profit_margin
FROM orders
GROUP BY 1
ORDER BY 1;


-- -------------------------------------------------------------------------
-- Q13. Payment mode & shipping mode preferences by region
-- -------------------------------------------------------------------------
SELECT
    region,
    payment_mode,
    COUNT(*) AS order_count,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY region), 1) AS pct_within_region
FROM orders
GROUP BY region, payment_mode
ORDER BY region, order_count DESC;
