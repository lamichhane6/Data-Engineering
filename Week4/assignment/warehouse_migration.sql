-- Week 4 — Warehouse Migration (Q4)
-- Run once against ride_warehouse, AFTER the class etl.py has been run at least twice:
--     psql -d ride_warehouse -f warehouse_migration.sql
-- See sql_assignment.md Q4 for the full requirements.

BEGIN;

-- 1. Deduplicate dim_driver
--    Re-point fact_trips.driver_key to the surviving copy (UPDATE ... FROM),
--    then DELETE the extra copies (DELETE ... USING).
WITH survivors AS (
    SELECT driver_id, MIN(driver_key) AS keeper_key
    FROM dim_driver
    GROUP BY driver_id
),
duplicates AS (
    SELECT d.driver_key, s.keeper_key
    FROM dim_driver d
    JOIN survivors s ON d.driver_id = s.driver_id
    WHERE d.driver_key <> s.keeper_key
)
UPDATE fact_trips f
SET driver_key = d.keeper_key
FROM duplicates d
WHERE f.driver_key = d.driver_key;

DELETE FROM dim_driver d
USING (
    SELECT driver_id, MIN(driver_key) AS keeper_key
    FROM dim_driver
    GROUP BY driver_id
) s
WHERE d.driver_id = s.driver_id
  AND d.driver_key <> s.keeper_key;


-- 1b. Deduplicate dim_passenger (same pattern)
WITH survivors AS (
    SELECT passenger_id, MIN(passenger_key) AS keeper_key
    FROM dim_passenger
    GROUP BY passenger_id
),
duplicates AS (
    SELECT p.passenger_key, s.keeper_key
    FROM dim_passenger p
    JOIN survivors s ON p.passenger_id = s.passenger_id
    WHERE p.passenger_key <> s.keeper_key
)
UPDATE fact_trips f
SET passenger_key = d.keeper_key
FROM duplicates d
WHERE f.passenger_key = d.passenger_key;

DELETE FROM dim_passenger p
USING (
    SELECT passenger_id, MIN(passenger_key) AS keeper_key
    FROM dim_passenger
    GROUP BY passenger_id
) s
WHERE p.passenger_id = s.passenger_id
  AND p.passenger_key <> s.keeper_key;


-- 2. UNIQUE constraints on dim_driver(driver_id) and dim_passenger(passenger_id)
ALTER TABLE dim_driver
    ADD CONSTRAINT uq_dim_driver_driver_id UNIQUE (driver_id);

ALTER TABLE dim_passenger
    ADD CONSTRAINT uq_dim_passenger_passenger_id UNIQUE (passenger_id);


-- 3. New fact_trips columns
--    time_key     INTEGER      -> FK to dim_time(time_key)
--    trip_status  VARCHAR(20)  -> CHECK: completed / cancelled / no_show
--    cancelled_by VARCHAR(10)  -> CHECK: driver / passenger / system
ALTER TABLE fact_trips
    ADD COLUMN time_key INTEGER REFERENCES dim_time(time_key),
    ADD COLUMN trip_status VARCHAR(20) CHECK (trip_status IN ('completed', 'cancelled', 'no_show')),
    ADD COLUMN cancelled_by VARCHAR(10) CHECK (cancelled_by IN ('driver', 'passenger', 'system'));


-- 4. Backfill time_key from requested_at (HHMM, minutes rounded down to 15)
UPDATE fact_trips
SET time_key = EXTRACT(HOUR FROM requested_at)::INTEGER * 100
             + (FLOOR(EXTRACT(MINUTE FROM requested_at)::NUMERIC / 15) * 15)::INTEGER;

COMMIT;
