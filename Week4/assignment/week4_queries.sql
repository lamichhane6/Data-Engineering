-- Week 4 Queries — Answers
-- Run against ride_warehouse unless a question says otherwise.
 -- ════════════════════════════════════════════════════════════════════════════
-- Part 1 — Audit the class warehouse (run the class etl.py TWICE first)
-- ════════════════════════════════════════════════════════════════════════════
 -- Q1 — Run it twice, get twice the drivers (Intermediate · GROUP BY / HAVING + constraints)
-- Row counts: dim_driver, dim_passenger, dim_location, fact_trips vs ride_prod source tables
 -- Row counts in ride_warehouse:

SELECT 'dim_driver' AS table_name,
       COUNT(*) AS row_count
FROM dim_driver
UNION ALL
SELECT 'dim_passenger',
       COUNT(*)
FROM dim_passenger
UNION ALL
SELECT 'dim_location',
       COUNT(*)
FROM dim_location
UNION ALL
SELECT 'fact_trips',
       COUNT(*)
FROM fact_trips;

-- (For comparison, in ride_prod: drivers=25, passengers=45, locations=25, trips=10000.
--  In ride_warehouse after two ETL runs: dim_driver=50, dim_passenger=90, dim_location=25, fact_trips=10000)
 -- 1. Duplicated driver_ids with copy count and every driver_key given:

SELECT driver_id,
       COUNT(*) AS copy_count,
       ARRAY_AGG(driver_key
                 ORDER BY driver_key) AS driver_keys
FROM dim_driver
GROUP BY driver_id
HAVING COUNT(*) > 1
ORDER BY driver_id;

-- 2. Pick one duplicated driver (e.g., driver_id = 1) and count fact_trips pointing to each driver_key:

SELECT d.driver_id,
       d.driver_key,
       COUNT(f.trip_key) AS trip_count
FROM dim_driver d
LEFT JOIN fact_trips f ON d.driver_key = f.driver_key
WHERE d.driver_id = 1
GROUP BY d.driver_id,
         d.driver_key
ORDER BY d.driver_key;

/*
Q1 Written Answers:
- Which copy do the facts actually use, and why that one?
  The facts point exclusively to driver_key = 1 (394 trips) and 0 trips point to driver_key = 26.
  This happens because on the first ETL run, driver_key = 1 was inserted and all 10,000 trips were
  loaded referencing that key. On the second ETL run, fact_trips had "ON CONFLICT (source_trip_id) DO NOTHING".
  Because all 10,000 trips were already present in fact_trips, the second run inserted 0 fact rows.
  Consequently, all fact rows still point to the first run's surrogate keys.

- load_dim_driver() says ON CONFLICT DO NOTHING. Why did that not prevent the duplicates?
  What has to exist on a table for there to be a conflict at all?
  In PostgreSQL, an ON CONFLICT clause requires an underlying UNIQUE constraint or unique index on the
  target conflict column(s). In warehouse.sql, dim_driver only had a primary key on driver_key (SERIAL);
  driver_id had NO UNIQUE constraint. The ETL executed:
      INSERT INTO dim_driver (...) VALUES (...) ON CONFLICT DO NOTHING;
  Because driver_key was an auto-incrementing serial and driver_id had no unique constraint, every insert
  generated a brand new driver_key and never triggered a unique constraint violation. Hence, no conflict occurred.

- Why did dim_location and fact_trips NOT duplicate, even though their loads ran twice as well?
  Point to the exact line in warehouse.sql that protects each one:
  1. dim_location: Line 50 of warehouse.sql specifies:
         location_id INTEGER NOT NULL UNIQUE,
     Because location_id is explicitly UNIQUE, subsequent runs encountered a conflict on location_id and were skipped.
  2. fact_trips: Line 80 of warehouse.sql specifies:
         source_trip_id INTEGER NOT NULL UNIQUE,
     Because source_trip_id is explicitly UNIQUE, subsequent runs encountered a conflict on source_trip_id and were skipped.

- If an analyst ran SELECT COUNT(*) FROM dim_driver to report "active drivers", what number would they report
  after a week of nightly runs?
  In ride_prod, there are 25 drivers (20 active). Without a UNIQUE constraint on driver_id, each nightly run adds
  25 duplicate rows. After 7 nightly runs, dim_driver would contain 25 * 7 = 175 rows total. If filtering by
  status = 'active', they would report 20 * 7 = 140 active drivers—reporting 7 times the actual number of active drivers.
*/ -- ════════════════════════════════════════════════════════════════════════════
-- Q2 — What the fact table can't answer (Design)
-- ════════════════════════════════════════════════════════════════════════════
 -- Attempting cancellation rate by month using duration_minutes IS NULL:

SELECT d.year,
       d.month,
       COUNT(*) AS total_trips,
       COUNT(*) FILTER (
                        WHERE f.duration_minutes IS NULL) AS uncompleted_trips,
       ROUND(100.0 * COUNT(*) FILTER (
                                      WHERE f.duration_minutes IS NULL) / COUNT(*), 2) AS uncompleted_rate_pct
FROM fact_trips f
JOIN dim_date d ON f.date_key = d.date_key
GROUP BY d.year,
         d.month
ORDER BY d.year,
         d.month;

/*
Q2 Written Answers:
1. State the grain of fact_trips in one sentence:
   The grain of fact_trips is one row per requested ride / trip booking in ride_prod.trips.

2. Why can't you answer the first question ("What's our cancellation rate by month?")?
   The initial fact_trips schema completely omitted trip status. While duration_minutes IS NULL can filter
   out trips that did not complete, it lumps together both 'cancelled' trips and 'no_show' trips.
   Product needs these kept strictly separate: a cancellation (driver or rider cancelled prior to pickup)
   has completely different root causes, customer experience impacts, and operational remedies than a no-show
   (where a driver arrived at the pickup location but the passenger never appeared).

3. Why can't you answer the second question ("Are fares higher during rush hour?")?
   Although dim_time exists with an is_rush_hour boolean column, fact_trips in the class schema had NO time_key
   foreign key column. It was completely orphaned from dim_time. While requested_at timestamp existed on the fact,
   analysts could not join dim_time without manually extracting hours and rounding minutes on the fly.

4. extract_trips() in etl.py already selects tc.cancelled_by. What happens to that value?
   Although extract_trips() retrieved tc.cancelled_by from the source join, transform_trip() ignored it
   and did not assign it to the transformed row dictionary. Furthermore, warehouse.sql did not define a
   cancelled_by column on fact_trips, so the value was discarded in memory and never stored in the warehouse.
*/ -- ════════════════════════════════════════════════════════════════════════════
-- Q3 — Averages of averages (Intermediate · semi-additive measures)
-- ════════════════════════════════════════════════════════════════════════════
-- Per year: true_avg_rating, avg_of_monthly_avgs, rated_trips, total_trips — in one query:
 WITH monthly_aggregates AS
  (SELECT d.year,
          d.month,
          COUNT(f.driver_rating) AS month_rated_trips,
          COUNT(*) AS month_total_trips,
          AVG(f.driver_rating) AS monthly_avg_rating,
          SUM(f.driver_rating) AS monthly_sum_rating
   FROM fact_trips f
   JOIN dim_date d ON f.date_key = d.date_key
   GROUP BY d.year,
            d.month)
SELECT year,
       ROUND(SUM(monthly_sum_rating)::NUMERIC / NULLIF(SUM(month_rated_trips), 0), 4) AS true_avg_rating,
       ROUND(AVG(monthly_avg_rating), 4) AS avg_of_monthly_avgs,
       SUM(month_rated_trips) AS rated_trips,
       SUM(month_total_trips) AS total_trips
FROM monthly_aggregates
GROUP BY year
ORDER BY year;

/*
Q3 Written Answers:
- Which year shows the biggest gap between the two averages? Why does averaging monthly averages give the wrong answer?
  2025 shows the largest gap (|4.4423 - 4.4415| = 0.0008, or 0.000735 unrounded).
  Averaging monthly averages produces the wrong result because it gives equal weight (1/N) to every month,
  ignoring the fact that each month has a different volume of rated trips. A true yearly average is a weighted
  average where months with more rated trips contribute proportionally more to the yearly average.
  Furthermore, 2026 has only 6 months of data in the dataset rather than 12, compounding distortion if assumptions
  about uniform yearly distribution are made.

- rated_trips is lower than total_trips. What does AVG do with the NULL ratings, and is that the behaviour you want here?
  PostgreSQL's AVG() aggregate ignores NULL values entirely (it computes SUM(driver_rating) / COUNT(driver_rating)).
  Yes, this is the exact behavior desired here. Trips that were not rated (or cancelled/no-shows) should not be
  treated as 0.0 stars; treating NULLs as 0 would catastrophically skew customer satisfaction metrics.

- Give one example of a column in fact_trips you CAN safely SUM, and one you must never SUM even though it's numeric:
  1. Safely SUM: fare_amount (or base_fare, tip_amount, discount_amount, distance_km). These are fully additive measures.
  2. Never SUM: surge_multiplier (or driver_rating, passenger_rating). surge_multiplier is an intensive ratio / multiplier;
     summing multipliers across trips is mathematically meaningless (it is a non-additive measure).
*/ -- ════════════════════════════════════════════════════════════════════════════
-- Part 2 — Q4 post-backfill checks
-- (the migration itself goes in warehouse_migration.sql;
--  run these AFTER `python etl_pipeline.py` has backfilled the new columns)
-- ════════════════════════════════════════════════════════════════════════════
 -- Q4 Verification: show zero fact_trips rows with NULL trip_status or time_key:

SELECT COUNT(*) FILTER (
                        WHERE trip_status IS NULL) AS null_trip_status,
       COUNT(*) FILTER (
                        WHERE time_key IS NULL) AS null_time_key
FROM fact_trips;

-- Apply NOT NULL constraints now that all rows are backfilled:

ALTER TABLE fact_trips
ALTER COLUMN trip_status
SET NOT NULL;


ALTER TABLE fact_trips
ALTER COLUMN time_key
SET NOT NULL;

/*
Q4 Comment:
- Why couldn't the SET NOT NULL go in the migration itself?
  When warehouse_migration.sql ran, fact_trips already contained 10,000 historical rows.
  Adding columns with NOT NULL immediately would fail with:
  "ERROR: column 'trip_status' of relation 'fact_trips' contains null values".
  Furthermore, trip_status (and cancelled_by) did not exist anywhere in ride_warehouse,
  so they could not be backfilled in pure warehouse SQL—they required the ETL pipeline in Part 3
  to extract the statuses from the OLTP source (ride_prod) and update existing fact rows.
  Only after the backfill script successfully populated all rows could the NOT NULL constraints be applied.
*/ -- ════════════════════════════════════════════════════════════════════════════
-- Part 4 — Query the star schema
-- ════════════════════════════════════════════════════════════════════════════
 -- Q5 — Monthly revenue by region, with share of month (Intermediate · star join + window)
-- 2025, completed: month, month_name, region, trips, revenue, pct_of_month
-- pct_of_month via SUM(SUM(fare_amount)) OVER (PARTITION BY ...)
 
SELECT d.month, 
       d.month_name, 
       l.region, 
       COUNT(*) AS trips, 
       ROUND(SUM(f.fare_amount), 2) AS revenue, 
       ROUND(100.0 * SUM(f.fare_amount) / SUM(SUM(f.fare_amount)) OVER (PARTITION BY d.month), 1) AS pct_of_month
FROM fact_trips f
JOIN dim_date d ON f.date_key = d.date_key
JOIN dim_location l ON f.pickup_location_key = l.location_key 
WHERE d.year = 2025 
  AND f.trip_status = 'completed'
GROUP BY d.month,
         d.month_name,
         l.region
ORDER BY d.month ASC,
         revenue DESC;

/*
Q5 Comment:
- Why filter on dim_date.year = 2025 rather than EXTRACT(YEAR FROM fact_trips.requested_at) = 2025?
  1. Performance and SARGability: Filtering on dim_date.year allows PostgreSQL to filter on an indexed
     integer date_key (or leverage partition pruning / index scans on the foreign key join). Using
     EXTRACT(YEAR FROM requested_at) requires applying a function to every row in the fact table, preventing
     index usage unless an expression index exists.
  2. Dimensional Modeling & Centralized Calendar Logic: dim_date pre-calculates and standardizes calendar
     attributes (fiscal periods, holidays, retail quarters, season). BI tools and analysts rely on consistent
     dimension filtering without rewriting date functions in every query.
*/ -- Q6 — Role-playing dimension: routes (Intermediate · same dim joined twice)
-- (1) Top 10 'pickup → dropoff' routes by completed trips, with revenue + avg distance_km

SELECT p.city_name || ' → ' || d.city_name AS route,
       COUNT(*) AS completed_trips,
       ROUND(SUM(f.fare_amount), 2) AS revenue,
       ROUND(AVG(f.distance_km), 2) AS avg_distance_km
FROM fact_trips f
JOIN dim_location p ON f.pickup_location_key = p.location_key
JOIN dim_location d ON f.dropoff_location_key = d.location_key
WHERE f.trip_status = 'completed'
GROUP BY p.city_name,
         d.city_name
ORDER BY completed_trips DESC
LIMIT 10;

-- (2) Cross-country trips / total trips / percentage (any status)

SELECT COUNT(*) FILTER (
                        WHERE p.country <> d.country) AS cross_border_trips,
       COUNT(*) AS total_trips,
       ROUND(100.0 * COUNT(*) FILTER (
                                      WHERE p.country <> d.country) / COUNT(*), 2) AS cross_border_pct
FROM fact_trips f
JOIN dim_location p ON f.pickup_location_key = p.location_key
JOIN dim_location d ON f.dropoff_location_key = d.location_key;

/*
Q6 Comment:
- What is a role-playing dimension, and why is joining dim_location twice under two aliases better
  than building dim_pickup_location and dim_dropoff_location tables?
  A role-playing dimension is a single physical dimension table that plays multiple distinct logical roles
  in the same fact table (here, pickup location and dropoff location).
  Joining dim_location twice under aliases (p and d) is superior to having separate tables because:
  1. Elimination of Redundancy (DRY): Locations share identical structures (city, state, country, lat/long).
     Separate tables would double maintenance overhead and require synchronizing two identical ETL pipelines.
  2. Consistency: Updating a city's metadata or region mapping in one table instantly updates both pickup
     and dropoff views with zero risk of data drift.
  3. Query Flexibility: Analysts can easily compare pickup and dropoff attributes (e.g. p.country <> d.country)
     without complex cross-table joins.
*/ -- Q7 — When do people ride, and when do they cancel? (Intermediate–Advanced · two dims + FILTER)
-- is_weekend x time_of_day: trips, avg_fare (completed), avg_surge, cancellation_rate_pct

SELECT d.is_weekend, 
       t.time_of_day, 
       COUNT(*) AS trips, 
       ROUND(AVG(f.fare_amount) FILTER (
                                        WHERE f.trip_status = 'completed'), 2) AS avg_fare, 
       ROUND(AVG(f.surge_multiplier), 2) AS avg_surge, 
       ROUND(100.0 * COUNT(*) FILTER (
                                      WHERE f.trip_status = 'cancelled') / COUNT(*), 2) AS cancellation_rate_pct
FROM fact_trips f
JOIN dim_date d ON f.date_key = d.date_key
JOIN dim_time t ON f.time_key = t.time_key
GROUP BY d.is_weekend,
         t.time_of_day
ORDER BY d.is_weekend,
         trips DESC;

-- Cancelled only: cancelled_by share, rush hour vs outside rush hour

SELECT t.is_rush_hour,
       f.cancelled_by,
       COUNT(*) AS cancellations,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY t.is_rush_hour), 2) AS pct_of_period_cancellations
FROM fact_trips f
JOIN dim_time t ON f.time_key = t.time_key
WHERE f.trip_status = 'cancelled'
GROUP BY t.is_rush_hour,
         f.cancelled_by
ORDER BY t.is_rush_hour DESC,
         cancellations DESC;

/*
Q7 Comment:
- Are fares higher during rush hour in this data?
  In this synthetic dataset, the average completed fare during rush hour is $84.45 (1,627 completed trips)
  compared to $81.00 outside rush hour (6,357 completed trips)—a slight difference of ~$3.45 (~4.2%).
  However, the average surge_multiplier is identical at 1.23 for both periods, indicating that the synthetic
  generator does not meaningfully simulate peak rush-hour surge pricing.

- Night has far more trips than any other bucket. Is that because people ride more at night?
  No, people do not ride more at night. This is an artifact of bucket duration in warehouse.sql:
    - Morning: 6 hours (06:00 to 11:59)
    - Afternoon: 5 hours (12:00 to 16:59)
    - Evening: 4 hours (17:00 to 20:59)
    - Night: 9 hours (21:00 to 05:59)
  Because the synthetic trip generator generates timestamps relatively uniformly across the 24 hours of the day,
  the Night bucket encompasses 9 out of 24 hours (37.5% of the entire day)—more than double the duration of Evening!
*/ -- Q8 — The tenure bucket that never changes (Advanced · dimension design)
-- Revenue by dim_driver.tenure_bucket (expect one bucket)

SELECT d.tenure_bucket,
       COUNT(*) AS completed_trips,
       ROUND(SUM(f.fare_amount), 2) AS revenue
FROM fact_trips f
JOIN dim_driver d ON f.driver_key = d.driver_key
WHERE f.trip_status = 'completed'
GROUP BY d.tenure_bucket;

-- Revenue / trips / distinct drivers by tenure AT TRIP TIME (requested_at - joined_at):

SELECT CASE
           WHEN f.requested_at - d.joined_at < INTERVAL '1 year' THEN '0-1 yr'
           WHEN f.requested_at - d.joined_at < INTERVAL '2 years' THEN '1-2 yrs'
           WHEN f.requested_at - d.joined_at < INTERVAL '3 years' THEN '2-3 yrs'
           ELSE '3+ yrs'
       END AS trip_tenure_bucket,
       COUNT(*) AS trips,
       ROUND(SUM(f.fare_amount), 2) AS revenue,
       COUNT(DISTINCT d.driver_id) AS distinct_drivers
FROM fact_trips f
JOIN dim_driver d ON f.driver_key = d.driver_key
WHERE f.trip_status = 'completed'
GROUP BY 1
ORDER BY 1;

/*
Q8 Comment:
- Why is a dimension attribute computed relative to NOW() a bad idea? The loads use ON CONFLICT DO NOTHING.
  When does a driver's tenure_bucket ever get recalculated?
  In extract_driver(), tenure_bucket is calculated using NOW() - joined_at. Because the dimension load uses
  ON CONFLICT (driver_id) DO NOTHING, existing driver records are never updated after insertion.
  Consequently, a driver's tenure_bucket is permanently frozen at the time their record was first ingested.
  Furthermore, since all drivers in the sample joined between March 2021 and October 2022, and the ETL was run in 2026,
  all drivers had joined > 2 years prior, landing 100% of drivers into '2+ years' upon initial load.

- Tenure at trip time is a property of the trip, not the driver. Where should it live in the model?
  Give one option and its trade-off:
  Option 1: As a measure / degenerate attribute directly on fact_trips (e.g. driver_tenure_days or driver_tenure_bucket).
  - Trade-off: Provides immediate, fast queries without requiring joins to dim_driver or interval math at runtime,
    faithfully capturing the exact point-in-time state of the driver when the trip occurred. The downside is added
    storage footprint on the fact table, and if bucket definitions change (e.g., product switches to 6-month intervals),
    retroactively backfilling billions of historical fact rows is costly.
  Option 2: Modeled through a Slowly Changing Dimension (SCD Type 2) or an Outrigger dimension.
  - Trade-off: Keeps the fact table lean and decouples driver lifecycle changes from the trip facts, but increases ETL
    complexity and requires date-effective range joins during fact extraction/loading.
*/ -- ════════════════════════════════════════════════════════════════════════════
-- Stretch — Slowly changing dimensions (Design · optional SQL)
-- ════════════════════════════════════════════════════════════════════════════
/*
1. After suspending driver 3 in ride_prod, dim_driver still says 'active' — is that a bug? Who would be misled, and how?
   Yes, this is a data staleness bug resulting from an append-only (DO NOTHING) ingestion strategy.
   Safety, trust, legal, and driver-operations teams querying the data warehouse would be misled. They would see
   driver 3 as 'active' and might conclude that suspended drivers are actively completing trips or available for dispatch.
   Fleet management reports on active driver counts would be artificially inflated.

2. SCD Type 1 (DO UPDATE):
   If we implement SCD Type 1 by overwriting:
       ON CONFLICT (driver_id) DO UPDATE SET status = EXCLUDED.status, ...
   What would a report of "2023 revenue by driver status" say about driver 3's trips from when they were active?
   SCD Type 1 overwrites the past. Driver 3's status becomes 'suspended' across the entire table.
   When running a report on historical 2023 trips grouped by driver status, all revenue driver 3 earned in 2023
   (when they were in good standing and active) will now be erroneously attributed to 'suspended' drivers!
   This corrupts historical reporting and audit trails.

3. SCD Type 2:
   SCD Type 2 preserves full history by creating new dimension rows whenever an attribute changes.
   Columns to add to dim_driver:
     - valid_from  TIMESTAMP NOT NULL (start timestamp for this version of the record)
     - valid_to    TIMESTAMP          (end timestamp when this version was superseded; NULL or '9999-12-31' for current)
     - is_current  BOOLEAN NOT NULL   (TRUE for the active version, FALSE for historical versions)

   Sketch of driver 3's rows after the change:
     Row 1 (historical):
       driver_key:  3
       driver_id:   3
       name:        'Alice Smith'
       status:      'active'
       valid_from:  '2021-03-20 10:48:11'
       valid_to:    '2026-10-03 12:00:00'
       is_current:  FALSE

     Row 2 (new current version):
       driver_key:  51 (new surrogate key)
       driver_id:   3
       name:        'Alice Smith'
       status:      'suspended'
       valid_from:  '2026-10-03 12:00:00'
       valid_to:    NULL
       is_current:  TRUE

4. Under Type 2:
   - Is UNIQUE (driver_id) still valid?
     No. A single driver_id will now exist across multiple rows (one row per historical version).
     The unique constraint would instead be on (driver_id, valid_from), or a partial unique index on:
         CREATE UNIQUE INDEX idx_driver_current ON dim_driver(driver_id) WHERE is_current = TRUE;

   - What must a trip's driver lookup match on instead?
     A simple dictionary lookup (driver_id -> driver_key) is no longer sufficient. The lookup must match both
     the natural key AND the event timestamp against the effective date window:
         SELECT d.driver_key
         FROM dim_driver d
         WHERE d.driver_id = trips.driver_id
           AND trips.requested_at >= d.valid_from
           AND (trips.requested_at < d.valid_to OR d.valid_to IS NULL);
*/