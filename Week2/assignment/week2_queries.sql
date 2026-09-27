-- Week 2 Queries — Answers
-- Fill in each query below. See sql_assignment.md for the full scenario text.

-- ─────────────────────────────────────────────────────────────────
-- Q1 — Rides per driver (Basic · JOIN + GROUP BY)
-- Ops wants a leaderboard: each driver's name and their total completed ride count, ordered by count descending.
-- Return: name, total_rides — completed rides only, ordered by total_rides desc
-- ─────────────────────────────────────────────────────────────────

SELECT 
    d.name,
    COUNT(t.trip_id) AS total_rides
FROM drivers d
JOIN trips t ON d.driver_id = t.driver_id
WHERE t.status = 'completed'
GROUP BY d.driver_id, d.name
ORDER BY total_rides DESC;



-- ─────────────────────────────────────────────────────────────────
-- Q2 — Drivers with zero completed rides (Intermediate · anti-join)
-- Onboarding wants to know which drivers in the drivers table have never completed a single ride —
-- including drivers who signed up but haven't driven yet (the extra driver inserted in Part 1, step 7).
-- Must be written as a LEFT JOIN where the matching row is missing, not as a subquery.
-- Return: name of every driver with no completed trip
-- ─────────────────────────────────────────────────────────────────

SELECT 
    d.name
FROM drivers d
LEFT JOIN trips t ON d.driver_id = t.driver_id AND t.status = 'completed'
WHERE t.trip_id IS NULL;



-- ─────────────────────────────────────────────────────────────────
-- Q3 — Average fare per pickup city (Intermediate · 3-table JOIN + AVG)
-- The expansion team wants each pickup city and the average fare of trips picked up there, ordered by average fare descending.
-- Return: city_name, avg_fare (rounded to 2 decimals) — ordered by avg_fare desc
-- ─────────────────────────────────────────────────────────────────

SELECT 
    l.city_name,
    ROUND(AVG(t.fare_amount), 2) AS avg_fare
FROM locations l
JOIN trips t ON l.location_id = t.pickup_location_id
GROUP BY l.location_id, l.city_name
ORDER BY avg_fare DESC;



-- ─────────────────────────────────────────────────────────────────
-- Q4 — Same-city driver/passenger trips (Basic–Intermediate · schema thinking)
-- A team lead asks: "Show me every trip where the driver and the passenger are from the same city."
-- Write the query you'd need to answer this — then, in a comment, answer:
-- 1. Does the current schema actually store a driver's or passenger's home city anywhere?
-- 2. If not, what table or column would you need to add?
-- 3. What would go wrong if you just added a home_city text column to drivers and passengers directly instead of referencing locations?
-- ─────────────────────────────────────────────────────────────────

-- Hypothetical query (assuming home_city_id foreign keys existed in drivers and passengers):
/*
SELECT 
    t.trip_id,
    d.name AS driver_name,
    p.name AS passenger_name,
    l.city_name AS shared_home_city
FROM trips t
JOIN drivers d ON t.driver_id = d.driver_id
JOIN passengers p ON t.passenger_id = p.passenger_id
JOIN locations l ON d.home_city_id = l.location_id
WHERE d.home_city_id = p.home_city_id;
*/

-- Explanation & Schema Analysis:
-- 1. Does the current schema store a driver's or passenger's home city anywhere?
--    No. The normalized schema only stores locations associated with individual trips
--    (pickup_location_id and dropoff_location_id). It records where a trip started and ended,
--    not the permanent residence / home city of either the driver or the passenger.
--
-- 2. What table or column would you need to add?
--    We would add a foreign key column to both user tables:
--      ALTER TABLE drivers ADD COLUMN home_city_id INTEGER REFERENCES locations(location_id);
--      ALTER TABLE passengers ADD COLUMN home_city_id INTEGER REFERENCES locations(location_id);
--    Alternatively, if users can have multiple addresses or profiles, a separate `user_addresses`
--    junction table could be created.
--
-- 3. What would go wrong if you added a raw text column `home_city VARCHAR(100)` directly?
--    a. Inconsistent Data & Typos: Without a foreign key constraint, text inputs are prone to
--       variations, typos, and casing/spacing mismatches (e.g., 'Kathmandu', 'kathmandu', 'KTM',
--       ' Kathmandu '). Two users from Kathmandu might not match in equality filters.
--    b. No Referential Integrity: Invalid or fabricated cities (e.g., 'N/A', 'Unknown', 'xyz')
--       could be entered without validation against a canonical list.
--    c. Update Anomalies & Storage Waste: Storing repeated city name strings across tens of thousands
--       of driver and passenger rows wastes disk space and makes city renaming (e.g., municipal boundary
--       changes) require expensive table-wide updates across multiple tables rather than updating a single
--       row in `locations`.



-- ─────────────────────────────────────────────────────────────────
-- Q5 — Re-run Week 1's revenue query (Basic · verification)
-- Total revenue from completed rides — must match your Week 1 answer
-- ─────────────────────────────────────────────────────────────────

SELECT 
    SUM(fare_amount) AS total_revenue
FROM trips
WHERE status = 'completed';



-- ─────────────────────────────────────────────────────────────────
-- Q6 — WHERE and HAVING, together (Intermediate · WHERE + GROUP BY + HAVING)
-- Find drivers with more than 280 completed rides AND total revenue over NPR 140,000.
-- Requires row-level filter (status = 'completed') before grouping,
-- and aggregate filters (COUNT > 280 and SUM > 140000) after grouping.
-- ─────────────────────────────────────────────────────────────────

SELECT 
    d.name,
    COUNT(t.trip_id) AS completed_rides,
    SUM(t.fare_amount) AS total_revenue
FROM drivers d
JOIN trips t ON d.driver_id = t.driver_id
WHERE t.status = 'completed'
GROUP BY d.driver_id, d.name
HAVING COUNT(t.trip_id) > 280
   AND SUM(t.fare_amount) > 140000
ORDER BY total_revenue DESC;



-- ─────────────────────────────────────────────────────────────────
-- Q7 — Clean the phone numbers (Intermediate · REGEXP_REPLACE)
-- Create temp scratch copy from rides, add phone_number column, populate messy data,
-- and write a SELECT producing clean digits-only numbers.
-- ─────────────────────────────────────────────────────────────────

-- Step 1: Create temporary scratch table from rides
SELECT * INTO TEMP temp_rides FROM rides;

-- Step 2: Add phone_number column
ALTER TABLE temp_rides ADD COLUMN phone_number VARCHAR(50);

-- Step 3: Populate sample rows with messy phone formats
UPDATE temp_rides 
SET phone_number = '98-4100 1234' 
WHERE ride_id = (SELECT MIN(ride_id) FROM temp_rides);

UPDATE temp_rides 
SET phone_number = '986 123 4567' 
WHERE ride_id = (SELECT MIN(ride_id) + 1 FROM temp_rides);

UPDATE temp_rides 
SET phone_number = '+977-980-123-4567' 
WHERE ride_id = (SELECT MIN(ride_id) + 2 FROM temp_rides);

-- Step 4: Digits-only SELECT using REGEXP_REPLACE
SELECT 
    phone_number AS original_phone,
    REGEXP_REPLACE(phone_number, '\D', '', 'g') AS clean_phone
FROM temp_rides
WHERE phone_number IS NOT NULL;

-- Explanation:
-- Plain REPLACE(string, from_str, to_str) only matches a single literal substring per call.
-- To remove hyphens, spaces, plus signs, brackets, etc., plain REPLACE requires clunky, deeply nested calls:
--   REPLACE(REPLACE(REPLACE(phone_number, '-', ''), ' ', ''), '+', '')
-- Furthermore, nested REPLACE fails whenever a new or unexpected delimiter (like dots, slashes, or letters) appears.
-- In contrast, REGEXP_REPLACE uses pattern matching. The character class `\D` (or `[^0-9]`) matches ANY non-digit
-- character, and the `'g'` (global) flag removes all occurrences across the entire string in a single, robust call.



-- ─────────────────────────────────────────────────────────────────
-- Q8 — Prove the city data is clean (Intermediate · STRPOS / ILIKE)
-- Write a query that returns any location whose name contains a space, using STRPOS.
-- Then write a second version of the same check using ILIKE.
-- ─────────────────────────────────────────────────────────────────

-- Version 1: Using STRPOS (returns the 1-based index if found, or 0 if not found)
SELECT 
    location_id,
    city_name
FROM locations
WHERE STRPOS(city_name, ' ') > 0;

-- Version 2: Using ILIKE (case-insensitive pattern matching with wildcard)
SELECT 
    location_id,
    city_name
FROM locations
WHERE city_name ILIKE '% %';

-- Verification Comment:
-- If both queries return 0 rows, that proves the migration was clean: no city names in `locations`
-- contain embedded spaces, trailing/leading whitespace, or un-split compound names.



-- ─────────────────────────────────────────────────────────────────
-- Q9 — Self-join: drivers who overlapped (Advanced · self-join + date functions)
-- Find pairs of DIFFERENT drivers who picked up a rider from the SAME pickup location
-- on the SAME calendar day.
-- Condition t1.driver_id < t2.driver_id:
--   1. Ensures a driver is never paired with themselves (t1.driver_id != t2.driver_id).
--   2. Prevents reciprocal duplicate pairs (e.g. keeps (Driver A, Driver B) and eliminates (Driver B, Driver A)).
-- ─────────────────────────────────────────────────────────────────

SELECT DISTINCT
    t1.requested_at::DATE AS pickup_date,
    loc.city_name AS pickup_location,
    d1.name AS driver_1,
    d2.name AS driver_2
FROM trips t1
JOIN trips t2 
    ON t1.pickup_location_id = t2.pickup_location_id
   AND t1.requested_at::DATE = t2.requested_at::DATE
   AND t1.driver_id < t2.driver_id
JOIN locations loc ON t1.pickup_location_id = loc.location_id
JOIN drivers d1 ON t1.driver_id = d1.driver_id
JOIN drivers d2 ON t2.driver_id = d2.driver_id
ORDER BY pickup_date, pickup_location, driver_1, driver_2;



-- ─────────────────────────────────────────────────────────────────
-- Q10 — Design challenge: promo codes (Design · no SQL required)
-- ─────────────────────────────────────────────────────────────────

/*
1. Recommended Schema & Tables:

   TABLE promo_codes (
       promo_code_id   SERIAL PRIMARY KEY,
       code            VARCHAR(50) NOT NULL UNIQUE,       -- e.g. 'SAVE10'
       discount_pct    NUMERIC(5,2) NOT NULL CHECK (discount_pct > 0 AND discount_pct <= 100),
       expires_at      TIMESTAMP NOT NULL,
       is_active       BOOLEAN NOT NULL DEFAULT TRUE,
       created_at      TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
   );

   TABLE trips (
       ... existing trip columns ...,
       promo_code_id   INTEGER REFERENCES promo_codes(promo_code_id), -- NULL if no promo applied
       discount_amount NUMERIC(10,2) DEFAULT 0.00                    -- Captured snapshot of discount value
   );

   (Optional Junction Table for Per-Passenger Limits):
   If business rules dictate that a rider can only use a given promo code once:
   TABLE passenger_promo_redemptions (
       redemption_id   SERIAL PRIMARY KEY,
       passenger_id    INTEGER NOT NULL REFERENCES passengers(passenger_id),
       promo_code_id   INTEGER NOT NULL REFERENCES promo_codes(promo_code_id),
       trip_id         INTEGER NOT NULL REFERENCES trips(trip_id),
       redeemed_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
       CONSTRAINT unique_passenger_promo UNIQUE (passenger_id, promo_code_id)
   );


2. Normal-Form Problem with the Flat-Column Approach:
   If `promo_code`, `discount_pct`, and `promo_expiry` are added as columns directly onto the `trips` table:

   - Transitive Dependency & Third Normal Form (3NF) Violation:
     In `trips`, the Primary Key is `trip_id`.
     Here:
       trip_id -> promo_code
       promo_code -> discount_pct, promo_expiry
     `discount_pct` and `promo_expiry` do not depend directly on the primary key `trip_id`;
     they depend functionally on `promo_code` (a non-key attribute). This transitive dependency
     explicitly violates Third Normal Form (3NF).

   - Resulting Anomalies:
     a. Redundancy & Wasted Space: If 10,000 riders use code 'SAVE10', the code string, discount percentage,
        and expiration timestamp are duplicated 10,000 times across disk.
     b. Update Anomaly: If the marketing team extends the promo expiration date or changes the discount,
        every existing trip row referencing that code must be updated. If any rows are missed or mid-transaction,
        data becomes inconsistent.
     c. Insertion Anomaly: A newly created promo code cannot exist in the database until at least one rider
        actually books a trip with it.
     d. Deletion Anomaly: If all trips that used an older promo code are archived or purged, all history and
        definitions of that promo code are permanently lost from the system.
*/
