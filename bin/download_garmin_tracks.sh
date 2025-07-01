#!/usr/bin/env bash

#
# Needs https://github.com/michael-simons/garmin-babel on the path
# Also configure
# export GARMIN_JWT=jwt_token_from_your_cookie_store_for_garmin
# export GARMIN_BACKEND_TOKEN=long_gibberish_token_from_one_of_the_requests
#
# In case you have very large activities, https://www.gpsbabel.org is needed
# to convert fit to gpx, otherwise they just be downloaded from Garmin, too
#

set -euo pipefail
export LC_ALL=en_US.UTF-8

DB="$(pwd)/$1"
GARMIN_ARCHIVE=$2
GARMIN_USER=$3
TARGET="$(pwd)/$4/f.csv"
TARGET_DIR="$(pwd)/$4"

# Run with additional fifth argument to download only selected activities
if [ -z "${5-}" ]; then
  START_DATE=$(duckdb "$DB" -noheader -list -readonly -c "select cast(max(started_on::date) + INTERVAL 1 day AS date) FROM garmin_activities WHERE gpx_available IS TRUE")

  garmin-babel --start-date="$START_DATE" "$GARMIN_ARCHIVE" dump-activities --user-name="$GARMIN_USER" --sport-type=RUNNING --min-distance=10 --download=gpx "$TARGET" --concurrent-downloads=1
  garmin-babel --start-date="$START_DATE" "$GARMIN_ARCHIVE" dump-activities --user-name="$GARMIN_USER" --sport-type=RUNNING --min-distance=10 --download=fit "$TARGET" --concurrent-downloads=1
  garmin-babel --start-date="$START_DATE" "$GARMIN_ARCHIVE" dump-activities --user-name="$GARMIN_USER" \
    --sport-type=CYCLING --activity-type=road_biking,gravel_cycling,cycling,mountain_biking,virtual_ride,indoor_cycling \
    --min-distance=75 --download=gpx "$TARGET" --concurrent-downloads=1
  garmin-babel --start-date="$START_DATE" "$GARMIN_ARCHIVE" dump-activities --user-name="$GARMIN_USER" \
    --sport-type=CYCLING --activity-type=road_biking,gravel_cycling,cycling,mountain_biking,virtual_ride,indoor_cycling \
    --min-distance=75 --download=fit "$TARGET" --concurrent-downloads=1
  rm "$TARGET"

# Or try in batches of n
else
  export BATCH_SIZE=$5

  QUERY="""
  SELECT string_agg(garmin_id, ',') AS ids
  FROM (
    SELECT garmin_id FROM garmin_activities
    WHERE activity_type IN (
        'road_biking','gravel_cycling','cycling','mountain_biking',
        'walking','hiking','running','track_running','casual_walking',
        'open_water_swimming'
      )
      AND NOT gpx_available ORDER BY started_on DESC
    LIMIT getenv('BATCH_SIZE')
  );
  """

  ids=$(duckdb "$DB" -noheader -list -readonly -c "$QUERY")
  if [ -n "${ids}" ]; then
    garmin-babel "$GARMIN_ARCHIVE" download-activities \
      --formats=fit,gpx \
      --user-name="$GARMIN_USER" \
      --concurrent-downloads=2 \
      --ids="$ids" \
      "$TARGET_DIR"
  fi

  # Sine mid june I came across files that timed out with http 408 on the API when asked for GPX, but downloaded just
  # fine as fit. The web app said "to large to download as GPX, try fit…", so here we are…
  IFS=, read -ra id_array <<< "$ids"
  for id in "${id_array[@]}"; do
    zip="$TARGET_DIR/$id".zip
    gpx="$TARGET_DIR/$id".gpx
    fit="$TARGET_DIR/$id"_ACTIVITY.fit
    if test -f $zip -a ! -f $gpx;  then
      echo "Using gpsbabel to convert fit to gpx..."
      unzip "$zip" -d "$TARGET_DIR"
      gpsbabel -i garmin_fit -f "$fit"  -o gpx -F "$gpx"
      rm "$fit"
    fi
  done
fi

if compgen -G "$TARGET_DIR/*.gpx" > /dev/null;
then
  find "$TARGET_DIR" -iname "*.gpx" -exec basename {} .gpx \; |
  duckdb "$DB" -s "
    UPDATE garmin_activities SET gpx_available = true
    WHERE garmin_id IN (
      FROM read_csv_auto('/dev/stdin')
    )
  "
fi
