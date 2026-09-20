-- Week 1 SQL Assignment — Answers
-- Fill in each query below. See sql_assignment.md for the full scenario text.

-- ─────────────────────────────────────────────────────────────────
-- Q1 — Kathmandu to Pokhara (Basic · DQL)
-- The support team is spot-checking pricing and wants every completed ride that went from Kathmandu to Pokhara.
-- Return: ride_id, driver_name, passenger_name, fare_amount
-- ─────────────────────────────────────────────────────────────────

SELECT 
    ride_id,
    driver_name,
    passenger_name,
    fare_amount
FROM rides
WHERE ride_status = 'completed'
  AND pickup_city = 'Kathmandu'
  AND dropoff_city = 'Pokhara';



-- ─────────────────────────────────────────────────────────────────
-- Q2 — Top 5 highest fares (Basic · DQL)
-- Finance wants to see the 5 most expensive rides ever recorded.
-- Return: driver_name, passenger_name, fare_amount — 5 highest fares, descending
-- ─────────────────────────────────────────────────────────────────

SELECT 
    driver_name,
    passenger_name,
    fare_amount
FROM rides
ORDER BY fare_amount DESC
LIMIT 5;



-- ─────────────────────────────────────────────────────────────────
-- Q3 — The "Shrestha" complaint (Basic · DQL)
-- Return every ride where driver_name contains "shrestha", regardless of case.
-- ─────────────────────────────────────────────────────────────────

SELECT *
FROM rides
WHERE driver_name ILIKE '%shrestha%';



-- ─────────────────────────────────────────────────────────────────
-- Q4 — How many rides were never rated? (Basic–Intermediate · NULL)
-- Return three columns in one query: total_rides, rated_rides, unrated_rides
-- ─────────────────────────────────────────────────────────────────

SELECT 
    COUNT(*) AS total_rides,
    COUNT(rating) AS rated_rides,
    COUNT(*) - COUNT(rating) AS unrated_rides
FROM rides;



-- ─────────────────────────────────────────────────────────────────
-- Q5 — Every ride that wasn't paid in cash (Intermediate · NULL)
-- Finance wants every ride that was not paid by cash — including rides where
-- payment method was never recorded (NULL).
-- Return: ride_id, driver_name, payment_method
-- ─────────────────────────────────────────────────────────────────

SELECT 
    ride_id,
    driver_name,
    payment_method
FROM rides
WHERE payment_method != 'cash' 
   OR payment_method IS NULL;



-- ─────────────────────────────────────────────────────────────────
-- Q6 — Revenue by pickup city (Intermediate · Aggregation)
-- For each pickup_city: total_rides, total_revenue (sum of fare_amount),
-- and avg_fare (rounded to 2 decimals). Sorted by total_revenue desc.
-- ─────────────────────────────────────────────────────────────────

SELECT 
    pickup_city,
    COUNT(*) AS total_rides,
    SUM(fare_amount) AS total_revenue,
    ROUND(AVG(fare_amount), 2) AS avg_fare
FROM rides
GROUP BY pickup_city
ORDER BY total_revenue DESC;



-- ─────────────────────────────────────────────────────────────────
-- Q7 — Ride outcomes by status (Intermediate · Aggregation)
-- For each ride_status: ride_status, ride_count, avg_distance_km (rounded to 2 decimals).
-- Sorted by ride_count desc.
-- ─────────────────────────────────────────────────────────────────

SELECT 
    ride_status,
    COUNT(*) AS ride_count,
    ROUND(AVG(ride_distance_km), 2) AS avg_distance_km
FROM rides
GROUP BY ride_status
ORDER BY ride_count DESC;



-- ─────────────────────────────────────────────────────────────────
-- Q8 — A new driver's first ride (Basic–Intermediate · DML)
-- 8a. INSERT adding the ride with ride_id = 9001 and rating left NULL
-- 8b. UPDATE setting rating = 4.8 for ride_id = 9001
-- ─────────────────────────────────────────────────────────────────

-- 8a. INSERT the new ride
INSERT INTO rides (
    ride_id,
    driver_name,
    passenger_name,
    pickup_city,
    dropoff_city,
    fare_amount,
    ride_distance_km,
    ride_status,
    requested_at,
    completed_at,
    rating,
    payment_method
) VALUES (
    9001,
    'Sunita Gurung',
    'Rajan Thapa',
    'Lalitpur',
    'Bhaktapur',
    350.00,
    12.4,
    'completed',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP,
    NULL,
    'cash'
);

-- 8b. UPDATE the rating to 4.8 for ride_id 9001
UPDATE rides
SET rating = 4.8
WHERE ride_id = 9001;



-- ─────────────────────────────────────────────────────────────────
-- Q9 — Locking down payment methods (Intermediate · DDL)
-- 9a. ALTER TABLE to restrict payment_method to only: 'cash', 'esewa', 'khalti', 'card', 'wallet'
-- 9b. INSERT using an invalid method (e.g. 'paypal') that will be rejected
-- ─────────────────────────────────────────────────────────────────

-- 9a. Add check constraint to restrict payment methods
ALTER TABLE rides
ADD CONSTRAINT check_payment_method 
CHECK (payment_method IN ('cash', 'esewa', 'khalti', 'card', 'wallet') OR payment_method IS NULL);

-- 9b. INSERT using an invalid payment method ('paypal')
INSERT INTO rides (
    ride_id,
    driver_name,
    passenger_name,
    pickup_city,
    dropoff_city,
    fare_amount,
    ride_distance_km,
    ride_status,
    requested_at,
    completed_at,
    rating,
    payment_method
) VALUES (
    9002,
    'Ram Shrestha',
    'Sita Sharma',
    'Kathmandu',
    'Lalitpur',
    250.00,
    5.0,
    'completed',
    CURRENT_TIMESTAMP,
    CURRENT_TIMESTAMP,
    5.0,
    'paypal'
);

-- Expected Error:
-- ERROR: new row for relation "rides" violates check constraint "check_payment_method"
-- DETAIL: Failing row contains (..., paypal).



-- ─────────────────────────────────────────────────────────────────
-- Q10 — Rides priced above the platform average (Basic · Subquery)
-- Return: ride_id, driver_name, fare_amount for every ride where fare_amount
-- is greater than the average fare_amount across all rides (using a subquery).
-- ─────────────────────────────────────────────────────────────────

SELECT 
    ride_id,
    driver_name,
    fare_amount
FROM rides
WHERE fare_amount > (
    SELECT AVG(fare_amount) 
    FROM rides
);
