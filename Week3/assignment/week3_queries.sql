-- Week 3 Queries — Answers
-- Database: ride_share

--------------------------------------------------------------------------------
-- Q1 — A bulk update that must not partially apply (Basic–Intermediate · transactions + CHECK)
--------------------------------------------------------------------------------

-- 1. All-or-nothing test: valid update + bad update -> whole batch rejected
BEGIN;

UPDATE trips
SET fare_amount = fare_amount * 1.1
WHERE driver_id = 1 AND status = 'completed';

-- Violates CHECK (fare_amount > 0)
UPDATE trips
SET fare_amount = -50.00
WHERE trip_id = 287;

ROLLBACK;

-- Verify no rows changed
SELECT count(*), round(sum(fare_amount), 2) AS total_fare
FROM trips
WHERE driver_id = 1 AND status = 'completed';

-- 2. Proper correction run alone and committed
BEGIN;

UPDATE trips
SET fare_amount = fare_amount * 1.1
WHERE driver_id = 1 AND status = 'completed';

COMMIT;

-- Verify fares changed
SELECT count(*), round(sum(fare_amount), 2) AS total_fare
FROM trips
WHERE driver_id = 1 AND status = 'completed';

-- Why all-or-nothing matters:
-- Without atomicity, a mid-batch failure leaves data partially updated. Re-running the script
-- would re-apply the 10% increase to already-updated rows (double-counting), leading to incorrect
-- driver payouts, corrupted accounting ledgers, and difficult manual reconciliation.


--------------------------------------------------------------------------------
-- Q2 — FK delete-rule audit (Intermediate · introspection + design)
--------------------------------------------------------------------------------

-- Introspection query:
SELECT
    tc.constraint_name,
    kcu.column_name,
    ccu.table_name AS foreign_table,
    ccu.column_name AS foreign_column,
    rc.delete_rule
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name AND tc.table_schema = kcu.table_schema
JOIN information_schema.referential_constraints rc
    ON tc.constraint_name = rc.constraint_name
JOIN information_schema.constraint_column_usage ccu
    ON ccu.constraint_name = tc.constraint_name AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' AND tc.table_name = 'trips';

/* Actual ON DELETE rules found:
trips_driver_id_fkey           | driver_id           | drivers         | driver_id          | CASCADE
trips_payment_method_id_fkey   | payment_method_id   | payment_methods | payment_method_id  | SET NULL
trips_passenger_id_fkey        | passenger_id        | passengers      | passenger_id       | NO ACTION
trips_pickup_location_id_fkey  | pickup_location_id  | locations       | location_id        | NO ACTION
trips_dropoff_location_id_fkey | dropoff_location_id | locations       | location_id        | NO ACTION
*/

-- 1. Demonstrate CASCADE on driver deletion:
INSERT INTO drivers (driver_id, name) VALUES (9999, 'Test Driver');
INSERT INTO trips (trip_id, driver_id, passenger_id, pickup_location_id, dropoff_location_id, fare_amount, distance_km, status, requested_at, payment_method_id)
VALUES (999901, 9999, 1, 1, 2, 100.0, 5.0, 'completed', NOW(), 1);

DELETE FROM drivers WHERE driver_id = 9999;
SELECT count(*) FROM trips WHERE driver_id = 9999; -- Returns 0 (trip deleted via CASCADE)

-- 2. Demonstrate SET NULL on payment method deletion:
INSERT INTO payment_methods (payment_method_id, name) VALUES (9999, 'Test PM');
INSERT INTO trips (trip_id, driver_id, passenger_id, pickup_location_id, dropoff_location_id, fare_amount, distance_km, status, requested_at, payment_method_id)
VALUES (999902, 1, 1, 1, 2, 100.0, 5.0, 'completed', NOW(), 9999);

DELETE FROM payment_methods WHERE payment_method_id = 9999;
SELECT trip_id, payment_method_id FROM trips WHERE trip_id = 999902; -- Returns NULL for payment_method_id

DELETE FROM trips WHERE trip_id = 999902;

-- Is CASCADE on driver_id safe?
-- No. Deleting a driver permanently deletes their trip history, erasing revenue, tax/VAT records,
-- and safety audit trails required by law.
-- Instead, use ON DELETE RESTRICT to block accidental deletion, combined with a `deleted_at`
-- soft-delete column on `drivers`.


--------------------------------------------------------------------------------
-- Q3 — Anti-join shootout: drivers with no trips (Intermediate–Advanced · EXPLAIN ANALYZE)
--------------------------------------------------------------------------------

-- (a) NOT IN
EXPLAIN ANALYZE
SELECT * FROM drivers WHERE driver_id NOT IN (SELECT driver_id FROM trips);
/*
Seq Scan on drivers (actual time=178.550..178.551 rows=1 loops=1)
  Filter: (NOT (ANY (driver_id = (SubPlan 1).col1)))
  SubPlan 1
    ->  Materialize (actual time=0.006..12.526 rows=83342 loops=12)
          ->  Seq Scan on trips (cost=0.00..23054.00 rows=1000000 width=4)
Execution Time: 180.720 ms
*/

-- (b) LEFT JOIN ... IS NULL
EXPLAIN ANALYZE
SELECT d.* FROM drivers d LEFT JOIN trips t ON d.driver_id = t.driver_id WHERE t.trip_id IS NULL;
/*
Hash Right Join (actual time=68.707..68.710 rows=1 loops=1)
  Hash Cond: (t.driver_id = d.driver_id)
  Filter: (t.trip_id IS NULL)
  ->  Seq Scan on trips t (cost=0.00..23054.00 rows=1000000 width=8)
  ->  Hash (cost=13.20..13.20 rows=320 width=222)
Execution Time: 68.732 ms
*/

-- (c) NOT EXISTS
EXPLAIN ANALYZE
SELECT * FROM drivers d WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.driver_id = d.driver_id);
/*
Hash Right Anti Join (actual time=63.803..63.806 rows=1 loops=1)
  Hash Cond: (t.driver_id = d.driver_id)
  ->  Seq Scan on trips t (cost=0.00..23054.00 rows=1000000 width=4)
  ->  Hash (cost=13.20..13.20 rows=320 width=222)
Execution Time: 63.818 ms
*/

-- Plan comparison:
-- NOT IN produced a Seq Scan with a Materialize subplan that spilled to disk (~180 ms, slowest).
-- LEFT JOIN ... IS NULL produced a Hash Right Join (~68 ms).
-- NOT EXISTS produced a Hash Right Anti Join (~63 ms, fastest due to short-circuiting).

-- NULL trap reproduction:
SELECT count(*) FROM trips WHERE payment_method_id IS NULL; -- Returns > 0

-- Fails silently (returns 0 rows):
SELECT * FROM payment_methods WHERE payment_method_id NOT IN (SELECT payment_method_id FROM trips);

-- Corrected with NOT EXISTS:
SELECT pm.* FROM payment_methods pm
WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.payment_method_id = pm.payment_method_id);

-- Why NOT IN breaks with NULL:
-- `x NOT IN (1, 2, NULL)` expands to `(x <> 1) AND (x <> 2) AND (x <> NULL)`.
-- Since any comparison with NULL yields UNKNOWN, the entire AND chain evaluates to UNKNOWN.
-- Because WHERE requires a TRUE result to return a row, all rows are rejected.


--------------------------------------------------------------------------------
-- Q4 — Index the fix (Intermediate · CREATE INDEX)
--------------------------------------------------------------------------------

-- Baseline without index:
EXPLAIN ANALYZE
SELECT pm.* FROM payment_methods pm
WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.payment_method_id = pm.payment_method_id);
/*
Hash Right Anti Join (cost=26.65..25780.82 rows=735 width=82) (actual time=122.488..122.489 rows=1 loops=1)
  Hash Cond: (t.payment_method_id = pm.payment_method_id)
  ->  Seq Scan on trips t (cost=0.00..23054.00 rows=1000000 width=4)
Execution Time: 122.578 ms
*/

-- Create index:
CREATE INDEX idx_trips_payment_method_id ON trips(payment_method_id);

-- Re-run with index:
EXPLAIN ANALYZE
SELECT pm.* FROM payment_methods pm
WHERE NOT EXISTS (SELECT 1 FROM trips t WHERE t.payment_method_id = pm.payment_method_id);
/*
Nested Loop Anti Join (cost=0.42..345.06 rows=735 width=82) (actual time=0.111..0.111 rows=1 loops=1)
  ->  Seq Scan on payment_methods pm
  ->  Index Only Scan using idx_trips_payment_method_id on trips t
Execution Time: 0.120 ms
*/

-- Did scan type change? Yes, from Hash Right Anti Join (Seq Scan) to Nested Loop Anti Join (Index Only Scan).
-- Execution time moved from ~122.6 ms to ~0.12 ms (improved by ~1,000x).


--------------------------------------------------------------------------------
-- Q5 — When not to index (Design · no new SQL required)
--------------------------------------------------------------------------------
-- Cost of an index:
-- Every INSERT, UPDATE, and DELETE becomes slower because Postgres must update each B-Tree index
-- in addition to the table. Indexes also consume RAM in shared_buffers and slow down VACUUM operations.

-- Index on trips.rating?
-- No. Rating has low cardinality (~41 distinct values), so queries have low selectivity.
-- Postgres will typically prefer a sequential scan over random index lookups.

-- Index on drivers.name?
-- Yes. Drivers is a small table with high cardinality and very few writes, making lookups by name
-- fast and inexpensive to maintain.


--------------------------------------------------------------------------------
-- Q6 — Driver performance summary (Intermediate–Advanced · aggregation view)
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW driver_performance_summary AS
SELECT
    d.driver_id,
    d.name AS driver_name,
    COUNT(t.trip_id) AS total_rides,
    COUNT(t.trip_id) FILTER (WHERE t.status = 'completed') AS total_completed_trips,
    COUNT(t.trip_id) FILTER (WHERE t.status = 'cancelled') AS total_cancelled_trips,
    COALESCE(
        ROUND(100.0 * COUNT(t.trip_id) FILTER (WHERE t.status = 'completed') / NULLIF(COUNT(t.trip_id), 0), 1),
        0.0
    ) AS completion_rate,
    COALESCE(
        ROUND(100.0 * COUNT(t.trip_id) FILTER (WHERE t.status = 'cancelled') / NULLIF(COUNT(t.trip_id), 0), 1),
        0.0
    ) AS cancellation_rate,
    COALESCE(ROUND(SUM(t.fare_amount) FILTER (WHERE t.status = 'completed'), 2), 0.00) AS total_revenue,
    ROUND(AVG(t.rating) FILTER (WHERE t.status = 'completed'), 2) AS avg_rating
FROM drivers d
LEFT JOIN trips t ON d.driver_id = t.driver_id
GROUP BY d.driver_id, d.name;

SELECT * FROM driver_performance_summary ORDER BY completion_rate ASC;


--------------------------------------------------------------------------------
-- Q7 — 7-day moving average fare (Advanced · window frame clause)
--------------------------------------------------------------------------------

WITH daily_series AS (
    SELECT
        requested_at::date AS trip_date,
        ROUND(AVG(fare_amount), 2) AS daily_avg_fare
    FROM trips
    WHERE status = 'completed'
    GROUP BY requested_at::date
)
SELECT
    trip_date,
    daily_avg_fare,
    ROUND(
        AVG(daily_avg_fare) OVER (
            ORDER BY trip_date
            ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
        ),
        2
    ) AS moving_avg_7d
FROM daily_series
ORDER BY trip_date;

-- First 6 days behavior:
-- Postgres aggregates only the available preceding rows (day 1 averages 1 row, day 2 averages 2, etc.).
-- These early rows represent a partial "warm-up" period and are more volatile, so they should be
-- treated as incomplete/unreliable for formal 7-day trend analysis.


--------------------------------------------------------------------------------
-- Q8 — Ranking ties, using your own view (Intermediate · ROW_NUMBER / RANK / DENSE_RANK)
--------------------------------------------------------------------------------

SELECT
    driver_id,
    driver_name,
    total_revenue,
    ROW_NUMBER() OVER (ORDER BY total_revenue DESC) AS row_num,
    RANK() OVER (ORDER BY total_revenue DESC) AS rnk,
    DENSE_RANK() OVER (ORDER BY total_revenue DESC) AS dense_rnk
FROM driver_performance_summary
ORDER BY total_revenue DESC;

-- Tie handling difference:
-- If two drivers tie at rank 2:
-- - ROW_NUMBER assigns sequential, distinct numbers (1, 2, 3); next driver gets 4.
-- - RANK assigns the same rank (2, 2) and skips numbers for the tie; next driver gets 4.
-- - DENSE_RANK assigns the same rank (2, 2) without skipping; next driver gets 3.


--------------------------------------------------------------------------------
-- Stretch — KPI, Metric, Dimension (Conceptual · no SQL required)
--------------------------------------------------------------------------------
/*
1. Definitions:
   - Dimension: A descriptive attribute used to slice, filter, or group data (e.g., driver_name, city, date).
   - Metric: A quantitative numeric value calculated by aggregating data (e.g., total_rides, total_revenue).
   - KPI: A strategic metric tied to specific business targets and tracked over time to measure performance.

2. Column Classification:
   - driver_id: Dimension
   - driver_name: Dimension
   - total_rides: Metric
   - total_completed_trips: Metric
   - total_cancelled_trips: Metric
   - completion_rate: Metric
   - cancellation_rate: Metric
   - total_revenue: Metric
   - avg_rating: Metric

3. Actual KPIs for a ride-share company:
   - completion_rate & cancellation_rate: Direct operational KPIs. Platforms enforce strict targets
     (e.g., >90% completion, <5% cancellation) to ensure marketplace liquidity and rider satisfaction.
   - avg_rating: Quality KPI. Platforms enforce minimum thresholds (e.g., 4.6/5.0) for driver retention.
   - total_revenue & total_rides: General volume metrics rather than driver-level KPIs, because they
     depend heavily on hours worked (part-time vs full-time) rather than performance against a standard target.
*/
