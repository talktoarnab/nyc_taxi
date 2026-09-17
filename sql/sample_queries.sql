-- Sample Athena queries for nyc_taxi.yellow_taxi_trips
-- Run in workgroup `nyc-taxi`. Partition projection needs a year/month filter
-- (or the engine generates the full 2014–2026 grid).

-- Row counts by month
SELECT year, month, count(*) AS trips
FROM nyc_taxi.yellow_taxi_trips
WHERE year BETWEEN 2024 AND 2026
GROUP BY 1, 2
ORDER BY 1, 2;

-- Revenue by pickup location (sample month)
SELECT pulocationid, round(sum(total_amount), 2) AS revenue, count(*) AS trips
FROM nyc_taxi.yellow_taxi_trips
WHERE year = 2024 AND month = 1
GROUP BY 1
ORDER BY revenue DESC
LIMIT 20;

-- Peak pickup hour
SELECT hour(tpep_pickup_datetime) AS hour_of_day, count(*) AS trips
FROM nyc_taxi.yellow_taxi_trips
WHERE year = 2024 AND month = 1
GROUP BY 1
ORDER BY 1;
