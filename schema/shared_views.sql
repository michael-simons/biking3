-- noinspection SqlResolveForFile

--
-- Aggregates the mileages per bike and month with the month being truncated to the first day of the month.
-- The mileage in this view is the amount of km travelled in that month, not the total value for the given bike any more.
--
CREATE OR REPLACE VIEW v$_mileage_by_bike_and_month AS (
  SELECT bike:  b.name,
         month: date_trunc('month', m.recorded_on - INTERVAL 1 MONTH),
         value: CAST(m.amount - coalesce(
           lag(m.amount) OVER (PARTITION BY m.bike_id ORDER BY m.recorded_on),
           if(month <> date_trunc('month', b.bought_on) , null, 0)
         ) AS DECIMAL(9,2))
  FROM bikes b
    JOIN milages m ON (m.bike_id = b.id)
  QUALIFY value IS NOT NULL
  ORDER BY bike, month
);


--
-- Aggregated mileage per month, including assorted trips
--
CREATE OR REPLACE VIEW v$_total_mileage_by_month AS (
  WITH sum_of_milages AS (
    SELECT month,
           sum(value) AS value
    FROM v$_mileage_by_bike_and_month
    GROUP BY month
  ), sum_of_assorted_trips AS (
    SELECT date_trunc('month', covered_on) AS month,
           sum(distance) AS value
    FROM assorted_trips
    GROUP BY month
  )
  SELECT m.month AS month,
         m.value + coalesce(t.value, 0) AS value
  FROM sum_of_milages m LEFT OUTER JOIN sum_of_assorted_trips t USING (month)
  ORDER BY month ASC
);


--
-- Common distance buckets by year and their pace percentiles
--
CREATE OR REPLACE VIEW v$_pace_percentiles_per_distance_and_year AS (
  SELECT CASE
           WHEN distance BETWEEN  4.75 AND  6.0 THEN '5'
           WHEN distance BETWEEN  9.5  AND 12.0 THEN '10'
           WHEN distance BETWEEN 19.95 AND 25.2 THEN '21'
           WHEN distance >= 42 THEN 'Marathon'
         END AS value,
         year(started_on) AS year,
         percentile_cont([0.0, 0.05, 0.5, 0.95, 1.0]) WITHIN GROUP(ORDER BY duration/distance DESC) AS percentiles
  FROM garmin_activities
  WHERE activity_type = 'running'
    AND value IS NOT NULL
  GROUP BY value, year
  ORDER BY try_cast(value AS integer) NULLS LAST, year
);


--
-- Last recorded mileage
--
CREATE OR REPLACE VIEW v$_last_mileage AS (
  WITH hlp(v) AS (
    SELECT CAST(recorded_on - INTERVAL 1 MONTH AS DATE) FROM milages
    UNION ALL
    SELECT covered_on FROM assorted_trips
  )
  SELECT last_day(max(v)) AS value FROM hlp
);
