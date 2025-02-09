INSTALL spatial;
LOAD spatial;

--
-- Computes the age group according to DLV / DLO, see
-- https://www.leichtathletik.de/fileadmin/user_upload/006_Wir-im-DLV/03_Struktur/DLV_Satzung_Ordnungen/Deutsche_Leichtathletik-Ordnung.pdf
--
CREATE OR REPLACE FUNCTION f_dlo_agegroup(ref_date) AS (
  WITH age_in_years AS (
    SELECT date_diff('year', value::date, ref_date::date) AS value
    FROM user_profile dob
    WHERE dob.name = 'date_of_birth'
  ), gender AS (
    SELECT CASE value WHEN 'male' THEN 'M' WHEN 'female' THEN 'W' ELSE '-' END AS value
    FROM user_profile
    WHERE name = 'gender'
  )
  SELECT
    CASE
      WHEN a.value >= 0  AND a.value < 7  THEN g.value || 'K U8'
      WHEN a.value >= 7  AND a.value < 12 THEN g.value || 'K U' || (20-(20-1-a.value)//2*2)
      WHEN a.value >= 12 AND a.value < 20 THEN g.value || 'J U' || (20-(20-1-a.value)//2*2)
      WHEN a.value >= 20 AND a.value < 23 THEN g.value || ' U23'
      WHEN a.value >= 23 AND a.value < 30 THEN g.value
      ELSE g.value || least((a.value // 5)*5, 95)
    END
  FROM age_in_years a, gender g
);


--
-- Computes the pace for a given distance in meters over a duration in seconds
--
CREATE OR REPLACE FUNCTION f_pace(distance, duration) AS (
  SELECT if(distance IS NOT NULL, cast(floor(duration/distance/60) AS int) || ':' || lpad(cast(round(duration/distance%60, 0)::int AS VARCHAR), 2, '0'), null)
);


--
-- Formats a duration in seconds as time hh:mm:ss
--
CREATE OR REPLACE FUNCTION f_format_duration(duration) AS (
  SELECT lpad(cast(duration//3600 AS VARCHAR), 2, '0') || ':' || lpad(cast((duration%3600)//60 AS VARCHAR), 2, '0') || ':' || lpad(cast(duration%3600%60 AS VARCHAR), 2, '0')
);


--
-- Turns a time value into a duration in seconds
--
CREATE OR REPLACE FUNCTION f_make_duration(time_value) AS (
  SELECT extract('hour' FROM time_value)*60*60 + extract('minute' FROM time_value)*60 + extract('second' FROM time_value)
);


--
-- Unifies a Garmin activity
--
CREATE OR REPLACE FUNCTION f_unify_activity_type(activity_type) AS (
  SELECT CASE
    WHEN activity_type IN ('gravel_cycling', 'mountain_biking', 'cycling', 'road_biking') THEN 'cycling'
    WHEN activity_type IN ('track_running', 'running', 'treadmill_running') THEN 'running'
    WHEN activity_type IN ('lap_swimming', 'open_water_swimming', 'swimming') THEN 'swimming'
    WHEN activity_type IN ('hiking', 'walking') THEN 'walking'
  END
);


--
-- Computes the tile number of a slippy map tile according to https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
-- @param p a POINT geometry
-- @param z the zoom level
-- @return struct(x integer, y integer, zoom integer)
--
CREATE OR REPLACE FUNCTION f_get_tile_number(p, z) AS (
    SELECT {
        x: CAST(floor((st_x(p) + 180) / 360 * (1<<z) ) AS integer),
        y: CAST(floor((1 - ln(tan(radians(st_y(p))) + 1 / cos(radians(st_y(p)))) / pi())/ 2* (1<<z)) AS integer),
        zoom: z
    }
);


--
-- Computes the bounding box of a slippy map tile according to https://wiki.openstreetmap.org/wiki/Slippy_map_tilenames
-- @param tile struct(x integer, y integer, z integer) containing the tile
-- @return POLYGON geometry representing a tile
--
CREATE OR REPLACE FUNCTION f_make_tile(tile) AS (
    SELECT
        ST_Reverse(ST_Extent_Agg(ST_Point(
            (tile['x'] + h[1]) / pow(2.0, tile['zoom']) * 360.0 - 180,
            degrees(atan(sinh(pi() - (2.0 * pi() * (tile['y'] + h[2])) / pow(2.0, tile['zoom']))))
        ))) FROM (SELECT unnest([[0, 0], [1, 0], [1, 1], [0, 1], [0, 0]]) as h)
);


--
-- Computes a feature collection of tiles that have not been explored inside the bbox given by the p_sw and p_se parameters.
-- @param p_sw Point2D Southwest of bbox
-- @param p_ne Point2D Northeast of bbox
-- @param p_zoom Zoom level to compute
-- @return a GeoJSON Feature collection
--
CREATE OR REPLACE FUNCTION f_unexplored_tiles(p_sw, p_ne, p_zoom) AS (
  WITH
    hlp AS (SELECT f_get_tile_number(p_sw, p_zoom) AS sw, f_get_tile_number(p_ne, p_zoom) AS ne),
    xy AS (
      SELECT x, y
      FROM hlp,
           generate_series(least(sw.x, ne.x), greatest(sw.x, ne.x)) AS _x(x),
           generate_series(least(sw.y, ne.y), greatest(sw.y, ne.y)) AS _y(y)
    ),
    old_tiles AS (
       SELECT *
       FROM tiles
       WHERE zoom = p_zoom
         AND ST_Intersects(ST_Extent(ST_Collect([p_sw, p_ne])), geom)
    ),
    new_tiles as (
      SELECT ST_AsGeoJSON(ST_ReducePrecision(f_make_tile({x: x, y: y, zoom: p_zoom}), 0.0001)) AS feature
      FROM xy ANTI JOIN old_tiles USING(x,y)
    )
  SELECT CAST({
      type: 'FeatureCollection',
      features: list(feature)
    } AS JSON) AS feature_collection
  FROM new_tiles
);


--
-- Formats a struct containing low and high values as l-h if they are unequal, as l if they are equal
-- @param p_lh a struct
--
CREATE OR REPLACE FUNCTION f_format_lh(p_lh) AS (
  SELECT CASE
    WHEN p_lh['low'] = p_lh['high'] THEN p_lh['low']::VARCHAR
    ELSE p_lh['low'] || '-' || p_lh['high'] END
);
