#!/usr/bin/env bash

set -euo pipefail
export LC_ALL=en_US.UTF-8

DB="$(pwd)/$1"
CSV_DIR="$(pwd)/$2"

duckdb $DB -s "
INSERT INTO assorted_trips SELECT * FROM '$CSV_DIR/assorted_trips.csv';
WITH
  m AS (SELECT generate_series(1, max(id)) AS r FROM assorted_trips),
  ids AS (SELECT unnest(r) FROM m)
SELECT count(nextval('assorted_trip_id')) FROM ids;

INSERT INTO bikes SELECT * EXCLUDE(url, label, last_milage) FROM '$CSV_DIR/bikes.csv';
UPDATE bikes SET created_at = date_trunc('second', created_at);
WITH
  m AS (SELECT generate_series(1, max(id)) AS r FROM bikes),
  ids AS (SELECT unnest(r) FROM m)
SELECT count(nextval('bike_id')) FROM ids;

INSERT INTO milages SELECT * FROM '$CSV_DIR/milages.csv';
WITH
  m AS (SELECT generate_series(1, max(id)) AS r FROM milages),
  ids AS (SELECT unnest(r) FROM m)
SELECT count(nextval('milage_id')) FROM ids;
UPDATE milages SET created_at = date_trunc('second', created_at);

INSERT INTO lent_milages SELECT * FROM '$CSV_DIR/lent_milages.csv';
WITH
  m AS (SELECT generate_series(1, max(id)) AS r FROM lent_milages),
  ids AS (SELECT unnest(r) FROM m)
SELECT count(nextval('lent_milage_id')) FROM ids;

UPDATE bikes SET color = replace(color,'#','');
UPDATE bikes SET color = '#' || upper(rpad(color, 6, substr(color,1,1)));

INSERT INTO events (name, type, one_time_only)
SELECT name, type, one_time_only FROM read_csv_auto('$CSV_DIR/events.csv', header=True)
ON CONFLICT (name) DO NOTHING;

WITH incoming AS (
  SELECT name, achieved_at, distance, list_transform(split(duration,':'), lambda x: x::integer) as time
  FROM '$CSV_DIR/results.csv'
) 
INSERT INTO results BY NAME
SELECT id AS event_id, achieved_at, time[1]*60*60 + time[2]*60 + time[3] AS duration, distance
FROM incoming i JOIN events e ON e.name = i.name
ON CONFLICT DO nothing;
"
