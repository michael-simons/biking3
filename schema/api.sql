-- noinspection SqlResolveForFile

INSTALL spatial;
LOAD spatial;

--
-- All active bikes
--
CREATE OR REPLACE VIEW v_active_bikes AS (
  SELECT * FROM bikes
  WHERE NOT miscellaneous
    AND decommissioned_on IS NULL
  ORDER BY name
);


--
-- All bikes, their last mileage and the years (as a list) in which they have been favoured over others.
--
CREATE OR REPLACE VIEW v_bikes AS (
  WITH mileage_by_bike_and_year AS (
    SELECT bike, year(month) AS year, sum(value) AS value
    FROM v$_mileage_by_bike_and_month
    GROUP BY all
  ), ranked_bikes AS (
    SELECT bike, year, dense_rank() OVER (PARTITION BY year ORDER BY value DESC) AS rnk
    FROM mileage_by_bike_and_year
    QUALIFY rnk = 1
    ORDER BY year
  ), years AS (
    SELECT bike, list(year ORDER BY year) AS value
    FROM ranked_bikes
    GROUP BY all
  ), lent AS (
    SELECT bike_id, sum(amount) AS value FROM lent_milages GROUP BY ALL
  ), last_milage AS (
     SELECT bike_id, last(amount) AS value
     FROM milages GROUP BY bike_id ORDER BY last(recorded_on)
  )
  SELECT bikes.*,
         coalesce(last_milage.value, 0) + coalesce(lent.value, 0) AS last_milage,
         coalesce(years.value, []) as favoured_in
  FROM bikes
  LEFT OUTER JOIN years ON years.bike = bikes.name
  LEFT OUTER JOIN lent ON lent.bike_id = bikes.id
  LEFT OUTER JOIN last_milage ON last_milage.bike_id = bikes.id
  WHERE NOT hide
  ORDER BY last_milage desc, bought_on, decommissioned_on, name
);


--
-- Summary over all bikes
--
CREATE OR REPLACE VIEW v_summary AS (
  WITH sum_of_milages AS (
    SELECT month,
           sum(value) AS value
    FROM v$_mileage_by_bike_and_month
    GROUP BY ROLLUP (month)
  ), sum_of_assorted_trips AS (
    SELECT date_trunc('month', covered_on) AS month,
           sum(distance) AS value
    FROM assorted_trips
    GROUP BY ROLLUP (month)
  ),
  summary AS (
    SELECT min(m.month)                                                                 AS since,
           max(m.month)                                                                 AS last_recording,
           arg_min(m.month, m.value + coalesce(t.value, 0)) FILTER (WHERE m.value <> 0) AS worst_month,
           min(m.value + coalesce(t.value, 0)) FILTER (WHERE m.value <> 0)              AS worst_month_value,
           arg_max(m.month, m.value + coalesce(t.value, 0))                             AS best_month,
           max(m.value + coalesce(t.value, 0))                                          AS best_month_value
    FROM sum_of_milages m LEFT OUTER JOIN sum_of_assorted_trips t USING (month)
    WHERE m.month IS NOT NULL
  )
  SELECT s.*,
         m.value + t.value                                     AS total,
         total / date_diff('month', s.since, s.last_recording) AS avg_per_month
  FROM sum_of_milages m,
       sum_of_assorted_trips t,
       summary s
  WHERE m.month IS NULL
    AND t.month IS NULL
    AND s.last_recording IS NOT NULL
);


--
-- Mileages over all bikes and assorted trips in the current year (year-today)
--
CREATE OR REPLACE VIEW v_ytd_summary AS (
  WITH
    lm AS (SELECT value FROM v$_last_mileage),
    sum_of_milages AS (
      SELECT month,
             sum(mbb.value) AS value
      FROM lm, v$_mileage_by_bike_and_month mbb
      WHERE month BETWEEN date_trunc('year', lm.value) AND date_trunc('month', lm.value)
      GROUP BY ROLLUP (month)
    ),
    sum_of_assorted_trips AS (
      SELECT date_trunc('month', covered_on) AS month,
             coalesce(sum(distance),      0) AS value
      FROM lm, assorted_trips
      WHERE month BETWEEN date_trunc('year', lm.value) AND date_trunc('month', lm.value)
      GROUP BY ROLLUP (month)
    ),
    summary AS (
      SELECT max(d.range)::date                                                  AS last_recording,
             arg_min(d.range, coalesce(m.value, 0) + coalesce(t.value, 0))::date AS worst_month,
             min(coalesce(m.value, 0) + coalesce(t.value, 0))                    AS worst_month_value,
             arg_max(d.range, coalesce(m.value, 0) + coalesce(t.value, 0))::date AS best_month,
             max(coalesce(m.value, 0) + coalesce(t.value, 0))                    AS best_month_value
      FROM lm, range(date_trunc('year', lm.value), date_trunc('year', lm.value) + interval 12 month, interval 1 month) d
        LEFT OUTER JOIN sum_of_milages m ON m.month = d.range
        LEFT OUTER JOIN sum_of_assorted_trips t ON t.month = d.range
      WHERE m.value IS NOT NULL OR t.value IS NOT NULL
    ),
    sum_of_milages_by_bike AS (
      SELECT bike,
             sum(mbb.value) AS value
      FROM lm, v$_mileage_by_bike_and_month mbb
      WHERE month BETWEEN date_trunc('year', lm.value) AND date_trunc('month', lm.value)
      GROUP BY bike
    )
  SELECT s.*,
         (SELECT arg_max(bike, value) FROM sum_of_milages_by_bike)                                           AS preferred_bike,
         coalesce(m.value, 0) + coalesce(t.value, 0)                                                         AS total,
         total / date_diff('month', date_trunc('year', lm.value), s.last_recording + interval 1 month) AS avg_per_month
  FROM lm,
       sum_of_milages m,
       sum_of_assorted_trips t,
       summary s
  WHERE m.month IS NULL
    AND t.month IS NULL
    AND s.last_recording IS NOT NULL
);


--
-- Monthly totals in the current year.
--
CREATE OR REPLACE VIEW v_ytd_totals AS (
  SELECT mbm.* replace(strftime(month, '%B') AS month)
  FROM v$_last_mileage lm, v$_total_mileage_by_month mbm
  WHERE month >= date_trunc('year', lm.value)
    AND month <= last_day(date_trunc('month', lm.value))
);


--
-- Monthly totals by bike in the current, can be safely pivoted on the bike.
--
CREATE OR REPLACE VIEW v_ytd_bikes AS (
    SELECT mbbm.*
    FROM v$_last_mileage lm, v$_mileage_by_bike_and_month mbbm
    JOIN bikes b ON (b.name = mbbm.bike)
    WHERE month >= date_trunc('year', lm.value)
      AND month <= last_day(date_trunc('month', lm.value))
      AND NOT b.miscellaneous
);


--
-- Monthly average over all, including 0 values for months in which no ride was done.
--
CREATE OR REPLACE VIEW v_monthly_average AS (
  WITH
    months AS (SELECT range AS value FROM range('2023-01-01'::date, '2024-01-01'::date, INTERVAL 1 month)),
    data AS (
      SELECT monthname(month)     AS month,
             min(value)           AS minimum,
             max(value)           AS maximum,
             round(avg(value), 2) AS average
      FROM v$_total_mileage_by_month x
      GROUP BY ROLLUP(monthname(month))
    )
  SELECT monthname(months.value)   AS month,
         coalesce(data.minimum, 0) AS minimum,
         coalesce(data.maximum, 0) AS maximum,
         coalesce(data.average, 0) AS average
  FROM months
     FULL OUTER JOIN data
    ON data.month = monthname(months.value)
  ORDER BY month(months.value)
);


--
-- Reoccurring events and their results. Results will be a structured list object per row.
--
CREATE OR REPLACE VIEW v_reoccurring_events AS (
  SELECT e.name, list({
    achieved_at: achieved_at,
    age_group: f_dlo_agegroup(achieved_at),
    distance: r.distance,
    time: f_format_duration(r.duration),
    pace: f_pace(r.distance, r.duration),
    certificate: if(certificate IS NOT NULL, strftime(achieved_at, '%Y-%m-%d') || ' ' || e.name || '.' || certificate, null),
    activity_id: g.garmin_id
  } ORDER BY achieved_at) AS results
  FROM events e JOIN results r ON r.event_id = e.id
  LEFT OUTER JOIN garmin_activities g ON g.garmin_id = r.activity_id AND g.gpx_available IS true
  WHERE NOT one_time_only
    AND (coalesce(getvariable('SHOW_ALL_REOCCURRING_EVENTS'),false) OR NOT HIDE)
  GROUP BY ALL
  ORDER BY e.name
);


--
-- One time only events and the explicit result therein.
--
CREATE OR REPLACE VIEW v_one_time_only_events AS (
  SELECT e.name,
         achieved_at,
         f_dlo_agegroup(achieved_at)    AS age_group,
         r.distance,
         f_format_duration(r.duration)  AS time,
         f_pace(r.distance, r.duration) AS pace,
         if(certificate IS NOT NULL, strftime(achieved_at, '%Y-%m-%d') || ' ' || e.name || '.' || certificate, null) AS certificate,
         g.garmin_id                 AS activity_id
  FROM events e JOIN results r ON r.event_id = e.id
  LEFT OUTER JOIN garmin_activities g ON g.garmin_id = r.activity_id AND g.gpx_available IS true
  WHERE one_time_only
    AND NOT hide
  GROUP BY ALL
  ORDER BY achieved_at, e.name
);


--
-- Aggregated mileages per year and bike up excluding the current year
--
CREATE OR REPLACE VIEW v_mileage_by_bike_and_year AS (
  WITH max_recordings AS (
    SELECT bike_id, max(recorded_on) AS value FROM milages GROUP BY bike_id
  )
  SELECT bikes.id AS id,
         name,
         year(recorded_on) - CASE WHEN recorded_on = mr.value AND strftime(mr.value, '%m-%d') <> '01-01' THEN 0 ELSE 1 END AS year,
         round(amount - coalesce(lag(amount) OVER (PARTITION BY name ORDER BY recorded_on),0)) AS mileage
  FROM bikes
    JOIN milages ON milages.bike_id = bikes.id
    JOIN max_recordings mr ON mr.bike_id = bikes.id
  WHERE (strftime(recorded_on, '%m-%d') = '01-01' OR (bikes.decommissioned_on IS NOT NULL AND recorded_on = mr.value))
  ORDER BY name, year
);


--
-- The median and p95 pace per distance (5k, 10k, 21k and Marathon) and year (formatted as MI:SS)
--
CREATE OR REPLACE VIEW v_pace_percentiles_per_distance_and_year AS (
  SELECT value AS distance, year,
         list_transform(percentiles, pace -> cast(floor(pace/60) AS int) || ':' || lpad(cast(round(pace%60, 0)::int AS VARCHAR), 2, '0')) AS percentiles
  FROM v$_pace_percentiles_per_distance_and_year
);


--
-- The median and p95 pace per distance (5k, 10k, 21k and Marathon) and year (as Seconds/METRE)
--
CREATE OR REPLACE VIEW v_pace_percentiles_per_distance_and_year_seconds AS (
  SELECT value AS distance, year, percentiles
  FROM v$_pace_percentiles_per_distance_and_year
);


--
-- Conducted maintenances
--
CREATE OR REPLACE VIEW v_maintenances AS (
  WITH src AS (
    SELECT b.id, name,
           conducted_on, milage,
           i.id AS item_id,
           {
             item: item,
             lasted: milage - lag(milage) OVER(PARTITION BY bike_id, item ORDER BY conducted_on)
           } AS item
    FROM bikes b
      JOIN bike_maintenance m ON m.bike_id = b.id
      JOIN bike_maintenance_line_items i ON maintenance_id = m.id
  )
  SELECT * EXCLUDE (item_id, item), list(item ORDER BY item_id) AS items
  FROM src
  GROUP BY ALL
  ORDER BY name, conducted_on
);


--
-- Specs
--
CREATE OR REPLACE VIEW v_specs AS (
  SELECT b.id, name, pos, item, removed
  FROM bikes b
    JOIN bike_specs s ON s.bike_id = b.id
  ORDER BY name, pos
);


--
-- Health metrics
--
CREATE OR REPLACE VIEW v_health_by_age AS (
  SELECT year(ref_date) AS year,
         last(ifnull(chronological_age, date_sub('year', dob.value::date, ref_date))) AS chronological_age,
         cast(round(avg(biological_age) FILTER (WHERE biological_age IS NOT NULL)) AS int) AS avg_biological_age,
         cast(round(avg(weight) FILTER (WHERE weight IS NOT NULL), 2) AS int) AS avg_weight,
         round(avg(body_fat) FILTER (WHERE body_fat IS NOT NULL), 2) AS avg_body_fat,
         cast(round(avg(resting_heart_rate) FILTER (WHERE resting_heart_rate IS NOT NULL)) AS int) AS avg_resting_heart_rate,
         cast(round(avg((blood_pressure.systolic.low + blood_pressure.systolic.high) / 2)) AS int) AS avg_systolic_bp,
         cast(round(avg((blood_pressure.diastolic.low + blood_pressure.diastolic.high) / 2)) AS int) AS avg_diastolic_bp,
         cast(round(avg(avg_stress_level) FILTER (WHERE avg_stress_level IS NOT NULL)) AS int) AS avg_stress_level,
         round(avg(vo2max_biometric) FILTER (WHERE vo2max_biometric IS NOT NULL), 2) AS avg_vo2max,
         round(avg(vo2max_running) FILTER (WHERE vo2max_running IS NOT NULL), 2) AS avg_vo2max_running,
         round(avg(vo2max_cycling) FILTER (WHERE vo2max_cycling IS NOT NULL), 2) AS avg_vo2max_cycling
  FROM health_metrics, user_profile dob
  WHERE dob.name = 'date_of_birth'
  GROUP BY ALL
  HAVING (
    avg_biological_age NOT NULL OR avg_resting_heart_rate NOT NULL OR
    avg_weight NOT NULL OR avg_body_fat NOT NULL
  )
  ORDER BY year
);


--
-- Measured body metrics
--
CREATE OR REPLACE VIEW v_body_metrics AS (
  SELECT ref_date,
         ifnull(chronological_age, date_sub('year', dob.value::date, ref_date)) AS chronological_age,
         weight,
         body_fat,
         coalesce(resting_heart_rate, blood_pressure.pulse) AS resting_heart_rate,
         f_format_lh(blood_pressure.systolic)  AS systolic,
         f_format_lh(blood_pressure.diastolic) AS diastolic
  FROM health_metrics, user_profile dob
  WHERE dob.name = 'date_of_birth'
  ORDER BY ref_date
);


--
-- SHOES
--
CREATE OR REPLACE VIEW v_shoes AS
SELECT make || ' ' || model AS name, * EXCLUDE(make, model)
FROM shoes
WHERE picture IS NOT NULL
 AND NOT hide
ORDER BY first_run_on, last_run_on;


--
-- Summarized distances by year and sport
--
CREATE OR REPLACE VIEW v_distances_by_year_and_sport AS
WITH sports AS (
  SELECT
    started_on,
    distance,
    f_unify_activity_type(activity_type) AS sport
  FROM garmin_activities
  WHERE sport IS NOT NULL
)
SELECT year(started_on) AS year, sport, round(sum(distance)) AS value
FROM sports
GROUP BY ALL
ORDER BY year, value DESC, sport;


--
-- Activity details that might be connected to actual verified race results
--
CREATE OR REPLACE VIEW v_activity_details AS
SELECT g.garmin_id                                AS id,
       strftime(coalesce(r.achieved_at, g.started_on), '%Y-%m-%d') || ': ' || coalesce(e.name, g.name)
                                                  AS name,
       coalesce(f_unify_activity_type(activity_type), sport_type)
                                                  AS activity_type,
       round(coalesce(r.distance, g.distance), 1) AS distance,
       coalesce(f_pace(r.distance, r.duration),f_pace(g.distance, g.duration))
                                                  AS pace,
       coalesce(f_format_duration(r.duration), f_format_duration(g.duration))
                                                  AS duration,
       round(g.elevation_gain)                    AS elevation_gain
FROM garmin_activities g
LEFT OUTER JOIN results r ON r.activity_id = g.garmin_id
LEFT OUTER JOIN events e ON e.id = r.event_id
WHERE coalesce(r.distance, g.distance) <> 0;


--
-- Computes streaks of n minutes of activity
--
CREATE OR REPLACE VIEW v_streaks AS
WITH duration_per_day AS (
  SELECT date_trunc('day', started_on)                                                   AS day,
         -- What defines a streak? More than n minutes activity per day
         max(duration) >= coalesce(getvariable('DURATION_PER_DAY'),30)*60                AS on_streak,
         -- Compute the island grouping key as difference of the monotonic increasing day
         -- and the dense_rank inside the on or off streak partition
         -- Using row_number() OVER (ORDER BY day) won't cut it, as that won't capture days
         -- without activities as all
         (day - INTERVAL (dense_rank() OVER (PARTITION BY on_streak ORDER BY day)) days) AS streak
  FROM garmin_activities
  GROUP BY day
), streaks AS (
  SELECT min(day) AS start, date_diff('day', start, max(day)) AS duration
  FROM duration_per_day
  GROUP BY on_streak, streak
  HAVING on_streak AND duration > 1
)
SELECT * FROM streaks
ORDER BY start;


--
-- v_longest_streak
--
CREATE OR REPLACE VIEW v_longest_streak AS
WITH longest AS (
    SELECT unnest(max_by(v_streaks, duration)) FROM v_streaks
), max_garmin AS (
    SELECT max(started_on)::date AS value FROM garmin_activities
) SELECT start, duration,
         CAST(start + INTERVAL (duration) day AS date) == max_garmin.value AS still_ongoing
FROM longest, max_garmin;
COMMENT ON VIEW v_longest_streak IS 'Retrieves the longest streak';


--
-- v_daily_activity_by_year
--
CREATE OR REPLACE VIEW v_daily_activity_by_year AS
WITH by_day AS (
    SELECT date_trunc('day', started_on)  AS day,
           CAST(floor(sum(duration) / 60) AS INTEGER)      AS duration
    FROM garmin_activities
    GROUP BY ALL
)
SELECT year (day) AS year, list(bd ORDER BY day) AS values
FROM by_day bd
GROUP BY ALL
ORDER BY ALL;
COMMENT ON VIEW v_daily_activity_by_year IS 'Daily minutes of activity by year';


--
-- Weekly averages by year and sport
--
CREATE OR REPLACE VIEW v_weekly_averages_by_year_and_sport AS
WITH range AS (
  SELECT unnest(range(min(started_on), max(started_on), interval 1 week)) AS value
  FROM garmin_activities
), fillers AS (
  SELECT yearweek(value) AS yw,
         s.unnest        AS sport,
         0               AS distance
  FROM range CROSS JOIN unnest(['swimming', 'cycling', 'running']) s
), activities AS (
  SELECT yearweek(started_on)                 AS yw,
         f_unify_activity_type(activity_type) AS sport,
         sum(distance)                        AS distance
  FROM garmin_activities
  WHERE sport IS NOT NULL
  GROUP BY all
), weekly_sums AS (
  SELECT ifnull(g.yw, f.yw)             AS yw,
         ifnull(g.sport, f.sport)       AS sport,
         ifnull(g.distance, f.distance) AS distance
  FROM fillers f
  LEFT OUTER JOIN activities g USING(yw, sport)
), weekly_avg_by_year AS (
  SELECT CAST(floor(yw/100) AS integer) AS year, sport, round(avg(distance),2) AS avg
  FROM weekly_sums
  GROUP BY all
)
PIVOT weekly_avg_by_year ON sport IN ('swimming', 'cycling', 'running')
USING first(avg) ORDER BY year;


--
-- v_explorer_summary
--
CREATE OR REPLACE VIEW v_explorer_summary AS
WITH
  biggest_clusters AS (
    SELECT count(*) AS num_tiles, zoom, round(ST_Area_Spheroid(ST_FlipCoordinates(ST_Union_Agg(geom))) / 1000000, 2) AS area
    FROM tiles
    WHERE cluster_index <> 0
    GROUP BY cluster_index, zoom
    QUALIFY dense_rank() OVER (PARTITION BY zoom ORDER BY num_tiles DESC) = 1
  ),
  starting_tiles AS (
    SELECT * FROM tiles WHERE square IS NOT NULL
  ),
  biggest_squares AS (
    SELECT t.zoom, s.square AS size, round(ST_Area_Spheroid(ST_FlipCoordinates(ST_Union_Agg(t.geom))) / 1000000, 2) AS area
    FROM tiles t
    JOIN starting_tiles s
        ON s.zoom = t.zoom AND t.x BETWEEN s.x AND s.x + s.square - 1 AND t.y BETWEEN s.y AND s.y + s.square - 1
    GROUP BY ALL
  )
SELECT count(*)                              AS total_tiles,
       tiles.zoom                            AS zoom,
       ifnull(biggest_squares.size, 0)       AS max_square,
       ifnull(biggest_squares.area, 0)       AS max_square_area,
       ifnull(biggest_clusters.num_tiles,0)  AS max_cluster,
       ifnull(biggest_clusters.area, 0)      AS max_cluster_area
FROM tiles
JOIN biggest_clusters USING(zoom)
JOIN biggest_squares USING(zoom)
GROUP BY ALL;
COMMENT ON VIEW v_explorer_summary IS 'Statistics about the explored tiles.';


--
-- v_explorer_clusters
--
CREATE OR REPLACE VIEW v_explorer_clusters AS
WITH
  biggest_cluster AS (
    SELECT cluster_index, count(*) AS num_tiles, zoom, ST_Union_Agg(geom) geom, dense_rank() OVER (PARTITION BY zoom ORDER BY num_tiles DESC) AS rnk
    FROM tiles
    WHERE cluster_index <> 0
    GROUP BY cluster_index, zoom
    QUALIFY rnk <= 20
  ),
  features AS (
    SELECT {
        type: 'Feature',
        geometry: ST_AsGeoJSON(ST_ReducePrecision(geom, 0.0001)),
        properties: {
          type: 'cluster',
          cluster: cluster_index,
          num_tiles: num_tiles
        }
    } AS feature, zoom, rnk
    FROM biggest_cluster
   ORDER BY cluster_index
  )
SELECT zoom, CAST({
  type: 'FeatureCollection',
  features: list(feature)
} AS JSON) AS feature_collection
FROM features
WHERE zoom = 17 OR rnk <=5
GROUP BY zoom;
COMMENT ON VIEW v_explorer_clusters IS 'The top n biggest clusters.';


--
-- v_explorer_tiles
--
CREATE OR REPLACE VIEW v_explorer_tiles AS
WITH
  biggest_cluster AS (
    SELECT ST_Union_Agg(geom) t, dense_rank() OVER (ORDER BY count(*)  DESC) AS rnk
    FROM tiles
    WHERE cluster_index <> 0 AND zoom = 17
    GROUP BY cluster_index, zoom
    QUALIFY rnk <= 20
  ),
  biggest_squares_starting_tiles AS (SELECT x, y, zoom, square FROM tiles WHERE square IS NOT NULL),
  features AS (
    SELECT DISTINCT {
        type: 'Feature',
        geometry: ST_AsGeoJSON(ST_ReducePrecision(geom, 0.0001)),
        properties: {
            type: 'tile',
            visited_count: visited_count,
            visited_first_on: visited_first_on,
            visited_last_on: visited_last_on,
            part_of_cluster: CASE WHEN tiles.cluster_index = 0 THEN 'n/a' ELSE concat('#', tiles.cluster_index) END
        }
    } AS feature, tiles.zoom, bg.t IS NOT NULL AS part_of_big_cluster, bs.square IS NOT NULL AS part_of_square
    FROM tiles
    LEFT OUTER JOIN biggest_cluster bg
      ON ST_Contains(bg.t, geom)
    LEFT OUTER JOIN biggest_squares_starting_tiles bs
      ON bs.zoom = tiles.zoom AND tiles.x BETWEEN bs.x AND bs.x + bs.square - 1 AND tiles.y BETWEEN bs.y AND bs.y + bs.square - 1
   WHERE visited_count > 0 AND tiles.cluster_index IS NOT NULL
   ORDER BY tiles.x, tiles.y
  )
SELECT zoom, CAST({
  type: 'FeatureCollection',
  features: list(feature)
} AS JSON) AS feature_collection
FROM features
WHERE zoom = 14 OR part_of_big_cluster OR part_of_square
GROUP BY zoom;
COMMENT ON VIEW v_explorer_tiles IS 'All tiles explored.';


--
-- v_explorer_squares
--
CREATE OR REPLACE VIEW v_explorer_squares AS
WITH
  starting_tiles AS (SELECT * FROM tiles WHERE square IS NOT NULL),
  features AS (
    SELECT {
       type: 'Feature',
       geometry:ST_AsGeoJSON(ST_ReducePrecision(ST_ConvexHull(ST_Union_Agg(t.geom)), 0.0001)),
       properties: {
           type: 'square',
           size: s.square
       }
    } as feature, s.zoom
    FROM tiles t, starting_tiles s
    WHERE t.x BETWEEN s.x AND s.x + s.square - 1
      AND t.y BETWEEN s.y AND s.y + s.square - 1
      AND t.zoom = s.zoom
    GROUP BY s.x, s.y, s.zoom, s.square
  )
SELECT zoom, CAST({
  type: 'FeatureCollection',
  features: list(feature)
} AS JSON) AS feature_collection
FROM features
GROUP BY zoom;
COMMENT ON VIEW v_explorer_squares IS 'The biggest square explored.';
