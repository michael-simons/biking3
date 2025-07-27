-- noinspection SqlResolveForFile

INSTALL spatial;
LOAD spatial;

--
-- Stores the managed bikes.
--
CREATE SEQUENCE IF NOT EXISTS bike_id;
CREATE TABLE IF NOT EXISTS bikes (
  id                  INTEGER PRIMARY KEY DEFAULT(nextval('bike_id')),
  name VARCHAR(255)   NOT NULL,
  bought_on           DATE NOT NULL,
  color               VARCHAR(6) DEFAULT 'CCCCCC' NOT NULL,
  decommissioned_on   DATE,
  created_at          DATETIME NOT NULL,
  miscellaneous       BOOLEAN NOT NULL DEFAULT FALSE,
  CONSTRAINT bikes_unique_name UNIQUE(name)
);
ALTER TABLE bikes ADD COLUMN IF NOT EXISTS hide BOOLEAN DEFAULT false;

--
-- Stores the total km travelled with any given bike once per month.
--
CREATE SEQUENCE IF NOT EXISTS milage_id;
CREATE TABLE IF NOT EXISTS milages (
  id                  INTEGER PRIMARY KEY DEFAULT(nextval('milage_id')),
  recorded_on         DATE CHECK (day(recorded_on) = 1) NOT NULL,
  amount              DECIMAL(8, 2) NOT NULL,
  created_at          DATETIME NOT NULL DEFAULT(now()),
  bike_id             INTEGER NOT NULL,
  CONSTRAINT milage_unique UNIQUE(bike_id, recorded_on),
  CONSTRAINT milage_bike_fk FOREIGN KEY(bike_id) REFERENCES bikes(id)
);


--
-- In the unlikely case of lending a bike to someone else, this table stores the mileage and trips of the bike while away.
--
CREATE SEQUENCE IF NOT EXISTS lent_milage_id;
CREATE TABLE IF NOT EXISTS lent_milages (
  id                        INTEGER PRIMARY KEY DEFAULT(nextval('lent_milage_id')),
  lent_on                   DATE NOT NULL,
  returned_on               DATE,
  amount /* in KILOMETRE */ DECIMAL(8, 2) NOT NULL,
  created_at                DATETIME NOT NULL,
  bike_id                   INTEGER NOT NULL,
  CONSTRAINT lent_milage_unique UNIQUE(bike_id, lent_on),
  CONSTRAINT lent_milage_bike_fk FOREIGN KEY(bike_id) REFERENCES bikes(id)
);
COMMENT ON COLUMN lent_milages.bike_id IS 'lent for';


--
-- Stores assorted or miscellaneous trips and rides, everything not done on a managed bike.
--
CREATE SEQUENCE IF NOT EXISTS assorted_trip_id;
CREATE TABLE IF NOT EXISTS  assorted_trips (
  id                          INTEGER PRIMARY KEY DEFAULT(nextval('assorted_trip_id')),
  covered_on                  DATE NOT NULL,
  distance /* in KILOMETRE */ DECIMAL(8, 2) NOT NULL
);


--
-- Stores event data.
--
CREATE SEQUENCE IF NOT EXISTS events_id;
CREATE TABLE IF NOT EXISTS events (
  id                  INTEGER PRIMARY KEY DEFAULT(nextval('events_id')),
  name VARCHAR(255)   NOT NULL,
  type                VARCHAR(32) CHECK (type IN ('cycling', 'running', 'swimming', 'Triathlon')) NOT NULL,
  one_time_only       BOOLEAN NOT NULL,
  CONSTRAINT events_unique_name UNIQUE(name)
);


--
-- Stores results in events.
--
CREATE TABLE IF NOT EXISTS results (
  event_id            INTEGER NOT NULL,
  achieved_at         DATE NOT NULL,
  duration            INTEGER NOT NULL,
  distance            DECIMAL(9, 3) NOT NULL,
  PRIMARY KEY (event_id, achieved_at),
  FOREIGN KEY (event_id) REFERENCES events(id)
);


--
-- Stores imported Garmin activities (See https://github.com/michael-simons/garmin-babel)
--
CREATE TABLE IF NOT EXISTS garmin_activities (
  garmin_id                     BIGINT PRIMARY KEY,
  name                          VARCHAR(512) NOT NULL,
  started_on                    TIMESTAMP  NOT NULL,
  activity_type                 VARCHAR(64) NOT NULL,
  sport_type                    VARCHAR(64),
  distance /* in KILOMETRE */   DECIMAL(9, 3),
  elevation_gain /* in METRE */ DECIMAL(9, 3),
  duration                      INTEGER NOT NULL,
  elapsed_duration              INTEGER,
  moving_duration               INTEGER ,
  v_o_2_max                     TINYINT,
  start_longitude               DECIMAL(9, 6),
  start_latitude                DECIMAL(8, 6),
  end_longitude                 DECIMAL(9, 6),
  end_latitude                  DECIMAL(8, 6),
  gear                          VARCHAR(512)
);


--
-- Add a flag whether the GPX data is available or not
--
ALTER TABLE garmin_activities ADD COLUMN IF NOT EXISTS gpx_available BOOLEAN DEFAULT false;

--
-- Add a flag whether the GPX data was processed into tiles or not
--
CREATE TABLE IF NOT EXISTS processed_zoom_levels (
    garmin_id BIGINT NOT NULL,
    zoom      UTINYINT NOT NULL,
    PRIMARY KEY (garmin_id, zoom),
    CONSTRAINT garmin_id_fk FOREIGN KEY(garmin_id) REFERENCES garmin_activities(garmin_id)
);

--
-- Add the device id
--
ALTER TABLE garmin_activities ADD COLUMN IF NOT EXISTS device_id BIGINT;

--
-- Add a certificate per result
--
ALTER TABLE results ADD COLUMN IF NOT EXISTS certificate BOOLEAN DEFAULT false;

--
-- Change certificate to type
--
ALTER TABLE results ALTER COLUMN certificate TYPE VARCHAR(8);
ALTER TABLE results ALTER COLUMN certificate SET DEFAULT NULL;
UPDATE results SET certificate = null WHERE certificate = 'false';
UPDATE results SET certificate = 'pdf' WHERE certificate = 'true';

--
-- Allow results without overall distance
--
ALTER TABLE results ALTER COLUMN distance DROP NOT NULL;

ALTER TABLE events ADD COLUMN IF NOT EXISTS hide BOOLEAN DEFAULT false;

--
-- Maintenance
--
CREATE SEQUENCE IF NOT EXISTS bike_maintenance_id;
CREATE TABLE IF NOT EXISTS bike_maintenance (
  id                        INTEGER PRIMARY KEY DEFAULT(nextval('bike_maintenance_id')),
  bike_id                   INTEGER NOT NULL,
  conducted_on              DATE NOT NULL,
  milage /* in KILOMETRE */ DECIMAL(8, 2) NOT NULL,
  CONSTRAINT bike_maintenance_unique UNIQUE(bike_id, conducted_on),
  CONSTRAINT bike_maintenance_bike_fk FOREIGN KEY(bike_id) REFERENCES bikes(id)
);

CREATE SEQUENCE IF NOT EXISTS maintenance_li_id;
CREATE TABLE IF NOT EXISTS bike_maintenance_line_items (
  id              INTEGER PRIMARY KEY DEFAULT(nextval('maintenance_li_id')),
  maintenance_id  INTEGER NOT NULL,
  item            VARCHAR(512) NOT NULL,
  CONSTRAINT line_item_maintenance_fk FOREIGN KEY(maintenance_id) REFERENCES bike_maintenance(id)
);


--
-- Specs
--
CREATE SEQUENCE IF NOT EXISTS bike_spec_id;
CREATE TABLE IF NOT EXISTS bike_specs (
  id                        INTEGER PRIMARY KEY DEFAULT(nextval('bike_spec_id')),
  bike_id                   INTEGER NOT NULL,
  pos                       INTEGER NOT NULL,
  item                      VARCHAR(512) NOT NULL,
  removed                   BOOLEAN NOT NULL DEFAULT false,
  CONSTRAINT bike_spec_bike_fk FOREIGN KEY(bike_id) REFERENCES bikes(id)
);


--
-- Health and fitness metrics
--
CREATE TABLE IF NOT EXISTS health_metrics (
  ref_date           DATE PRIMARY KEY,
  chronological_age  UTINYINT,
  biological_age     DECIMAL(5,2),
  weight             DECIMAL(5,2),
  body_fat           DECIMAL(5,2),
  resting_heart_rate UTINYINT,
  vo2max_biometric   DECIMAL(5,2),
  vo2max_running     DECIMAL(5,2),
  vo2max_cycling     DECIMAL(5,2),
  avg_stress_level   UTINYINT,
  min_heart_rate     UTINYINT,
  max_heart_rate     UTINYINT,
  body_water         DECIMAL(5,2),
  bone_mass          DECIMAL(5,2),
  muscle_mass        DECIMAL(5,2),
  lowest_spo2_value  UTINYINT
);

ALTER TABLE health_metrics ADD COLUMN IF NOT EXISTS blood_pressure STRUCT(systolic UTINYINT, diastolic UTINYINT, pulse UTINYINT);
ALTER TABLE health_metrics DROP COLUMN IF EXISTS blood_pressure;
ALTER TABLE health_metrics ADD COLUMN IF NOT EXISTS blood_pressure STRUCT(
    systolic  STRUCT(low UTINYINT, high UTINYINT),
    diastolic STRUCT(low UTINYINT, high UTINYINT),
    pulse UTINYINT
);

--
-- Shoes
--
CREATE SEQUENCE IF NOT EXISTS shoe_id;
CREATE TABLE IF NOT EXISTS shoes (
  id                 INTEGER PRIMARY KEY DEFAULT(nextval('shoe_id')),
  make               VARCHAR(128) NOT NULL,
  model              VARCHAR(256) NOT NULL,
  first_run_on       DATE NOT NULL,
  last_run_on        DATE,
  last_milage        INTEGER,
  picture            STRUCT(filename VARCHAR(32), last_run BOOLEAN, milage INTEGER)
);
ALTER TABLE shoes ADD COLUMN IF NOT EXISTS hide BOOLEAN DEFAULT false;


--
-- Cooper tests
--
CREATE TABLE IF NOT EXISTS cooper_test_results (
  taken_on           DATE PRIMARY KEY,
  result             DECIMAL(9, 3) NOT NULL
);


--
-- Profil data
--
CREATE TABLE IF NOT EXISTS user_profile (
  name  VARCHAR(128) PRIMARY KEY,
  value VARCHAR(512) NOT NULL
);


--
-- Garmin devices
--
CREATE TABLE IF NOT EXISTS garmin_devices (
  device_id                     BIGINT PRIMARY KEY,
  product_name                  VARCHAR(256) NOT NULL,
  serial_number                 VARCHAR(16) NOT NULL,
  part_number                   VARCHAR(32) NOT NULL
);


--
-- Serial number for older stuff not known
--
ALTER TABLE garmin_devices ALTER COLUMN serial_number DROP NOT NULL;


--
-- Optionally link Garmin activities to results (add foreign keys not supported, would require dropping and recreating the table)
--
ALTER TABLE results ADD COLUMN IF NOT EXISTS activity_id BIGINT NULL;


--
-- Explored tiles
--
CREATE TABLE IF NOT EXISTS tiles (
    x                BIGINT NOT NULL,
    y                BIGINT NOT NULL,
    zoom             UTINYINT NOT NULL,
    geom             GEOMETRY NOT NULL,
    visited_count    INT NOT NULL,
    visited_first_on DATE NOT NULL,
    visited_last_on  DATE NOT NULL,
    cluster_index    INT,
    square           UTINYINT,
    PRIMARY KEY (x, y, zoom)
);


--
-- Explored administrative areas
--
ALTER TABLE garmin_activities ADD COLUMN IF NOT EXISTS administrative_areas_processed BOOLEAN DEFAULT false;
CREATE SEQUENCE IF NOT EXISTS administrative_area_id;
CREATE TABLE IF NOT EXISTS administrative_areas (
    id BIGINT PRIMARY KEY DEFAULT(nextval('administrative_area_id')),
    parent_id BIGINT NOT NULL,
    country_code VARCHAR(3) NOT NULL,
    level UTINYINT NOT NULL,
    name VARCHAR(256) NOT NULL,
    visited_count INTEGER NULL,
    visited_first_on DATE NULL,
    visited_last_on DATE NULL,
    envelope GEOMETRY NOT NULL,
    CONSTRAINT unique_area UNIQUE(parent_id, name)
);
ALTER TABLE administrative_areas ADD COLUMN IF NOT EXISTS coverage STRUCT(
    zoom UTINYINT,
    percentage DECIMAL(5, 2)
)[];


--
-- Fries and other important point of interests
--
CREATE SEQUENCE IF NOT EXISTS poi_id;
CREATE TABLE IF NOT EXISTS poi (
    id BIGINT PRIMARY KEY DEFAULT(nextval('poi_id')),
    type VARCHAR(8) DEFAULT 'fries' NOT NULL,
    name VARCHAR(128) NOT NULL,
    visited_on DATE NOT NULL,
    link VARCHAR(128) NOT NULL,
    link_type VARCHAR(8) DEFAULT 'absolute' CHECK (link_type IN ('absolute', 'relative')) NOT NULL,
    longitude DECIMAL(9, 6) NOT NULL,
    latitude DECIMAL(8, 6) NOT NULL
);
