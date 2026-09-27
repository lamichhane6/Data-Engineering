"""
extensions.py
─────────────
P1: parameterized query function
P2: generic table printer (cursor.description)
P3: handle a bad insert gracefully (FK violation + rollback)
"""

import os
import psycopg2
from dotenv import load_dotenv


def get_connection():
    load_dotenv()
    return psycopg2.connect(
        host=os.getenv("DB_HOST"),
        port=os.getenv("DB_PORT"),
        dbname=os.getenv("DB_NAME"),
        user=os.getenv("DB_USER"),
        password=os.getenv("DB_PASSWORD"),
    )


# P1: parameterized query function
def get_rides_for_driver(cur, driver_name):
    """Return every trip for the given driver name (case-insensitive)."""
    # Using parameterized queries (%s) avoids SQL injection vulnerabilities that arise
    # from string formatting or concatenation. It also correctly handles names with
    # special characters like apostrophes (e.g. O'Connor) without breaking SQL syntax.
    sql = """
        SELECT 
            t.trip_id,
            d.name AS driver_name,
            t.status,
            t.fare_amount,
            t.distance_km,
            t.requested_at
        FROM trips t
        JOIN drivers d ON t.driver_id = d.driver_id
        WHERE LOWER(d.name) = LOWER(%s)
        ORDER BY t.requested_at;
    """
    cur.execute(sql, (driver_name,))
    return cur.fetchall()


# P2: generic table printer
def run_and_print(cur, sql):
    """Run any SELECT query and print an aligned table using cur.description."""
    cur.execute(sql)
    headers = [col.name for col in cur.description]
    rows = cur.fetchall()

    if not rows:
        print(" | ".join(headers))
        print("(0 rows)\n")
        return

    widths = [
        max(len(str(h)), max((len(str(r[i])) for r in rows), default=0))
        for i, h in enumerate(headers)
    ]

    header_line = " | ".join(f"{h:<{widths[i]}}" for i, h in enumerate(headers))
    separator_line = "-+-".join("-" * widths[i] for i in range(len(headers)))

    print(header_line)
    print(separator_line)
    for row in rows:
        print(" | ".join(f"{str(val if val is not None else ''):<{widths[i]}}" for i, val in enumerate(row)))
    print(f"({len(rows)} rows)\n")


# P3: handle a bad insert gracefully
def insert_trip_with_bad_driver(conn):
    """Attempt an INSERT with a driver_id that doesn't exist; recover cleanly."""
    bad_driver_id = 999999
    bad_insert_sql = """
        INSERT INTO trips (
            driver_id, passenger_id, pickup_location_id, dropoff_location_id,
            fare_amount, distance_km, status, requested_at
        ) VALUES (
            %s, 1, 1, 1, 500.00, 10.5, 'completed', NOW()
        );
    """

    print(f"Attempting to insert a trip with invalid driver_id ({bad_driver_id})...")
    try:
        with conn.cursor() as cur:
            cur.execute(bad_insert_sql, (bad_driver_id,))
            conn.commit()
    except psycopg2.IntegrityError as e:
        print(f"Foreign key constraint error caught: Driver ID {bad_driver_id} does not exist.")
        conn.rollback()
        print("Transaction rolled back successfully.")

    print("\nVerifying connection is still usable after rollback:")
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM drivers;")
        driver_count = cur.fetchone()[0]
        print(f"Query succeeded: total drivers count = {driver_count}")


# Queries for P2 from Week 2 SQL assignment
Q1_SQL = """
    SELECT 
        d.name,
        COUNT(t.trip_id) AS total_rides
    FROM drivers d
    JOIN trips t ON d.driver_id = t.driver_id
    WHERE t.status = 'completed'
    GROUP BY d.driver_id, d.name
    ORDER BY total_rides DESC;
"""

Q3_SQL = """
    SELECT 
        l.city_name,
        ROUND(AVG(t.fare_amount), 2) AS avg_fare
    FROM locations l
    JOIN trips t ON l.location_id = t.pickup_location_id
    GROUP BY l.location_id, l.city_name
    ORDER BY avg_fare DESC;
"""

Q6_SQL = """
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
"""


def main():
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            print("--- P1: Parameterized query for driver 'rajan pandey' ---")
            rides = get_rides_for_driver(cur, "rajan pandey")
            print(f"Found {len(rides)} trips for 'rajan pandey'.")
            if rides:
                print(f"First record: {rides[0]}")
            print()

            print("--- P2: Generic table printer (Q1: Rides per driver) ---")
            run_and_print(cur, Q1_SQL)

            print("--- P2: Generic table printer (Q3: Average fare per city) ---")
            run_and_print(cur, Q3_SQL)

            print("--- P2: Generic table printer (Q6: High volume & revenue drivers) ---")
            run_and_print(cur, Q6_SQL)

        print("--- P3: Handle bad insert & rollback ---")
        insert_trip_with_bad_driver(conn)

    finally:
        conn.close()
        print("\nConnection closed.")


if __name__ == "__main__":
    main()
