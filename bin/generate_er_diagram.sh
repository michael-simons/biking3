#!/usr/bin/env bash

#
# Creates a Mermaid Diagram from the given schema
#

set -euo pipefail
export LC_ALL=en_US.UTF-8

DIR="$(dirname "$(realpath "$0")")"

QUERY="""
COPY (
    WITH hlp AS (
        SELECT referenced_table, c.table_name,
               trim(string_agg(d.comment, ' ')) AS comment,
               list_reduce(constraint_column_names, lambda x,y: concat(x, ',', y)) AS columns
        FROM duckdb_constraints() c
        JOIN duckdb_columns d ON d.table_name = c.table_name AND list_contains(c.constraint_column_names, d.column_name)
        WHERE constraint_type = 'FOREIGN KEY'
        GROUP BY ALL
    )
    SELECT 'erDiagram'
    UNION ALL
    SELECT format(
                '    {:s} {{{:s}}}',
                table_name,
                string_agg(lower(if(data_type like '%(%', substr(data_type,1, strpos(data_type, '(') -1), data_type)) || ' ' || column_name, ' ')
           )
    FROM duckdb_tables() t
    JOIN duckdb_columns() c USING (table_name)
    GROUP BY table_name
    UNION ALL
    SELECT format(
                '    {:s} ||--o{{ {:s} : \"{:s}\"',
                referenced_table,
                table_name,
                ifnull(comment, columns)
            )
    FROM hlp
    ) TO '/dev/stdout' (header false, quote '', delimiter E'\n')
;
"""

echo "$QUERY" | cat "$DIR/../schema/base_tables.sql" /dev/stdin | duckdb
