# This script evaluates one or more CSV files exported from Garmin.com with German language
# settings and checks for activities that starts with NRFTW and generates a progress view
# for https://katjas-laufzeit.de/no-rest-for-the-wicked-ausschreibung-2025/.
# 2025 results are here: https://my.raceresult.com/298701/live

.nullvalue ''
.print

WITH
  src AS (
    SELECT DISTINCT ON (Datum, Titel)
           *, extract('hour' FROM Zeit)*60*60 + extract('minute' FROM Zeit)*60 + extract('second' FROM Zeit) AS Duration
    FROM read_csv('*.csv', union_by_name=True, filename=False)
    WHERE Titel LIKE 'NRFTW%'
  ),
  activities AS (
    SELECT "Day #"      : dense_rank() OVER (ORDER BY Datum::DATE),
           "Day"        : Datum::DATE,
           "Run #"      : row_number() OVER (),
           "Break"      : age(Datum, coalesce(date_add(lag(Datum) OVER starts, INTERVAL (lag(Duration) OVER starts) Second), Datum))::VARCHAR,
           "Hour of day": hour(Datum),
           "Weekday"    : dayname(Datum),
           "Sport"      : CASE Aktivitätstyp
                            WHEN 'Gehen'  THEN 'Walking'
                            WHEN 'Laufen' THEN 'Running'
                            ELSE Aktivitätstyp
                          END,
           "Distance"   : replace(Distanz, ',', '.')::NUMERIC,
           "Duration"   : extract('hour' FROM Zeit)*60*60 + extract('minute' FROM Zeit)*60 + extract('second' FROM Zeit),
           "Progress"   : 100/24,
    FROM src
    WINDOW starts AS (ORDER BY Datum)
  ),
  sums AS (
    SELECT * REPLACE(
               round(sum(Distance), 2)   AS Distance,
               to_seconds(sum(Duration)) AS Duration,
               sum(Progress) OVER dates  AS Progress
           ),
           "p_weekdays" : count(DISTINCT Weekday) OVER (ORDER BY Day GROUPS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING),
           "Weekdays"   : count(DISTINCT Weekday) OVER dates
    FROM activities
    GROUP BY GROUPING SETS (("Day #", "Run #", Day, "Hour of day", Progress, Weekday, Break, Sport), ("Day #", Day), ())
    WINDOW dates AS (ORDER BY Day)
  )
SELECT * EXCLUDE(p_weekdays) REPLACE (
           Break::INTERVAL AS Break,
           CASE WHEN "Hour of day" IS NULL AND p_weekdays <> 7 AND Weekdays = 7 THEN '✅' END AS Weekdays,
           CASE
             WHEN Day           IS NULL THEN lpad(printf('%.2f%%', Progress), 7, ' ')
             WHEN "Hour of day" IS NULL THEN lpad(printf('%.2f%%', Progress), 7, ' ') || ' ' || bar(Progress, 0, 100, 20) END AS Progress
         )
FROM sums
ORDER BY Day, "Hour of day" NULLS LAST;
