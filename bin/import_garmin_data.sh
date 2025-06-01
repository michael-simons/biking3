#!/usr/bin/env bash

#
# Needs https://github.com/michael-simons/garmin-babel and
# bin/export_fitness_metrics.sh as garmin-export-fitness-metrics
# on the path.
#

set -euo pipefail
export LC_ALL=en_US.UTF-8

DB="$(pwd)/$1"
GARMIN_ARCHIVE=$2
GARMIN_USER=$3

garmin-babel "$GARMIN_ARCHIVE" dump-activities --user-name="$GARMIN_USER" |
duckdb "$DB" -s "
  INSERT INTO garmin_activities BY NAME (
    SELECT * EXCLUDE(avg_speed, max_speed) REPLACE(coalesce(name, 'n/a') AS name)
    FROM read_csv_auto('/dev/stdin')
  )
  ON CONFLICT DO UPDATE SET device_id = CASE WHEN excluded.device_id = 0 THEN null ELSE device_id END
"

garmin-export-fitness-metrics "$GARMIN_ARCHIVE" |
duckdb "$DB" -s "
  INSERT INTO health_metrics BY NAME (
    SELECT COLUMNS(lambda c: c NOT LIKE 'bp\_%' ESCAPE '\'),
           CASE WHEN bp_systolic IS NOT NULL AND bp_diastolic IS NOT NULL THEN
              {'systolic':  list_reduce(split(bp_systolic, '-'), lambda l, h: {low: l::UTINYINT, high: h::UTINYINT}),
               'diastolic': list_reduce(split(bp_diastolic, '-'), lambda l, h: {low: l::UTINYINT, high: h::UTINYINT}),
               'pulse':     bp_pulse::UTINYINT}
           ELSE NULL END AS blood_pressure
    FROM read_csv_auto('/dev/stdin')
  ) ON CONFLICT DO NOTHING
"
