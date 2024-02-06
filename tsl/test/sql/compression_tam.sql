-- This file and its contents are licensed under the Timescale License.
-- Please see the included NOTICE for copyright information and
-- LICENSE-TIMESCALE for a copy of the license.

SET timescaledb.arrow_cache_maxsize = 4;

CREATE TABLE readings(time timestamptz UNIQUE, location int, device int, temp float, humidity float);

SELECT create_hypertable('readings', 'time');
-- Disable incremental sort to make tests stable
SET enable_incremental_sort = false;
SELECT setseed(1);

INSERT INTO readings (time, location, device, temp, humidity)
SELECT t, ceil(random()*10), ceil(random()*30), random()*40, random()*100
FROM generate_series('2022-06-01'::timestamptz, '2022-07-01', '5s') t;

ALTER TABLE readings SET (
	  timescaledb.compress,
	  timescaledb.compress_orderby = 'time',
	  timescaledb.compress_segmentby = 'device'
);

-- Set some test chunks as global variables
SELECT format('%I.%I', chunk_schema, chunk_name)::regclass AS chunk
  FROM timescaledb_information.chunks
 WHERE format('%I.%I', hypertable_schema, hypertable_name)::regclass = 'readings'::regclass
 LIMIT 1 \gset

SELECT format('%I.%I', chunk_schema, chunk_name)::regclass AS chunk2
  FROM timescaledb_information.chunks
 WHERE format('%I.%I', hypertable_schema, hypertable_name)::regclass = 'readings'::regclass
 ORDER BY chunk2 DESC
 LIMIT 1 \gset

-- We do some basic checks that the compressed data is the same as the
-- uncompressed. In this case, we just count the rows for each device.
SELECT device, count(*) INTO orig FROM readings GROUP BY device;

-- Initially an index on time
SELECT * FROM test.show_indexes(:'chunk');

EXPLAIN (verbose, costs off)
SELECT count(*) FROM :chunk
WHERE time = '2022-06-01'::timestamptz;

SELECT count(*) FROM :chunk
WHERE time = '2022-06-01'::timestamptz;

SELECT count(*) FROM :chunk
WHERE location = 1;

-- We should be able to set the table access method for a chunk, which
-- will automatically compress the chunk.
ALTER TABLE :chunk SET ACCESS METHOD tscompression;
SET timescaledb.enable_transparent_decompression TO false;

-- Show access method used on chunk
SELECT c.relname, a.amname FROM pg_class c
INNER JOIN pg_am a ON (c.relam = a.oid)
WHERE c.oid = :'chunk'::regclass;

-- This should show the chunk as compressed
SELECT chunk_name FROM chunk_compression_stats('readings') WHERE compression_status='Compressed';

-- Should give the same result as above
SELECT device, count(*) INTO comp FROM readings GROUP BY device;

-- Row counts for each device should match, so this should be empty.
SELECT device FROM orig JOIN comp USING (device) WHERE orig.count != comp.count;

EXPLAIN (verbose, costs off)
SELECT count(*) FROM :chunk
WHERE time = '2022-06-01'::timestamptz;

SELECT count(*) FROM :chunk
WHERE time = '2022-06-01'::timestamptz;

-- Create a new index on a compressed column
CREATE INDEX ON readings (location);

-- Index added on location
SELECT * FROM test.show_indexes(:'chunk');

-- Query by location should be an index scan
EXPLAIN (verbose, costs off)
SELECT count(*) FROM :chunk
WHERE location = 1;

-- Count by location should be the same as non-index scan before
-- compression above
SELECT count(*) FROM :chunk
WHERE location = 1;


-- Test that a conflict happens when inserting a value that already exists in the
-- compressed part of the chunk
SELECT count(*) FROM :chunk WHERE time  = '2022-06-01'::timestamptz;

\set ON_ERROR_STOP 0
INSERT INTO readings VALUES ('2022-06-01', 1, 1, 1.0, 1.0);
-- Same result if inserted directly into the compressed chunk
INSERT INTO :chunk VALUES ('2022-06-01', 1, 1, 1.0, 1.0);
\set ON_ERROR_STOP 1

-- Test insert of a non-conflicting value into the compressed chunk,
-- first directly into chunk and then via hypertable. The value should
-- end up in the non-compressed part in contrast to the conflicting
-- value above.
INSERT INTO :chunk VALUES ('2022-06-01 00:00:02', 1, 1, 1.0, 1.0);
INSERT INTO readings VALUES ('2022-06-01 00:00:03', 1, 1, 1.0, 1.0);

SELECT * FROM readings WHERE time BETWEEN '2022-06-01'::timestamptz AND '2022-06-01 01:00'::timestamptz ORDER BY time ASC LIMIT 10;

-- Inserting the same values again should lead to conflicts
\set ON_ERROR_STOP 0
INSERT INTO :chunk VALUES ('2022-06-01 00:00:02', 1, 1, 1.0, 1.0);
INSERT INTO readings VALUES ('2022-06-01 00:00:03'::timestamptz, 1, 1, 1.0, 1.0);
\set ON_ERROR_STOP 1
SELECT device, count(*) FROM readings WHERE device=1 GROUP BY device;
-- Speculative insert when conflicting row is in the non-compressed part
INSERT INTO :chunk VALUES ('2022-06-01 00:00:02', 2, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 11;
-- Show the updated tuple
SELECT * FROM readings WHERE time = '2022-06-01 00:00:02'::timestamptz;
INSERT INTO readings VALUES ('2022-06-01 00:00:02', 3, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 12;
SELECT * FROM readings WHERE time = '2022-06-01 00:00:02'::timestamptz;

-- Speculative insert when conflicting row is in the compressed part
INSERT INTO :chunk VALUES ('2022-06-01', 2, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 13;
SELECT * FROM readings WHERE time = '2022-06-01'::timestamptz;
INSERT INTO readings VALUES ('2022-06-01', 3, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 14;
SELECT * FROM readings WHERE time = '2022-06-01'::timestamptz;

-- Speculative insert without a conflicting
INSERT INTO :chunk VALUES ('2022-06-01 00:00:06', 2, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 15;
SELECT * FROM readings WHERE time = '2022-06-01 00:00:06';
INSERT INTO readings VALUES ('2022-06-01 00:00:07', 3, 1, 1.0, 1.0) ON CONFLICT (time) DO UPDATE SET location = 16;
SELECT * FROM readings WHERE time = '2022-06-01 00:00:07';

INSERT INTO readings VALUES ('2022-06-01', 3, 1, 1.0, 1.0) ON CONFLICT (time) DO NOTHING;

SET enable_indexscan = false;

-- Columnar scan with qual on segmentby where filtering should be
-- turned into scankeys
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;

-- Show with indexscan
SET enable_indexscan = true;
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;
SET enable_indexscan = false;

-- Compare the output to transparent decompression. Heap output is
-- shown further down.
SET timescaledb.enable_transparent_decompression TO true;
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;
SET timescaledb.enable_transparent_decompression TO false;

-- Qual on compressed column with index
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk WHERE location < 4 ORDER BY time, device LIMIT 5;
SELECT * FROM :chunk WHERE location < 4 ORDER BY time, device LIMIT 5;

-- With index scan
SET enable_indexscan = true;
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk WHERE location < 4 ORDER BY time, device LIMIT 5;
SELECT * FROM :chunk WHERE location < 4 ORDER BY time, device LIMIT 5;
SET enable_indexscan = false;

-- With transparent decompression
SET timescaledb.enable_transparent_decompression TO true;
SELECT * FROM :chunk WHERE location < 4 ORDER BY time, device LIMIT 5;
SET timescaledb.enable_transparent_decompression TO false;

-- Ordering on compressed column that has index
SET enable_indexscan = true;
EXPLAIN (costs off, timing off, summary off)
SELECT * FROM :chunk ORDER BY location ASC LIMIT 5;
SELECT * FROM :chunk ORDER BY location ASC LIMIT 5;

-- Show with transparent decompression
SET timescaledb.enable_transparent_decompression TO true;
SELECT * FROM :chunk ORDER BY location ASC LIMIT 5;
SET timescaledb.enable_transparent_decompression TO false;

-- Test that filtering is not removed on ColumnarScan when it includes
-- columns that cannot be scankeys.
DROP INDEX readings_location_idx;
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT * FROM :chunk WHERE device < 4 AND location = 2 LIMIT 5;

-- Test that columnar scan can be turned off
SET timescaledb.enable_columnarscan = false;
EXPLAIN (analyze, costs off, timing off, summary off)
SELECT * FROM :chunk WHERE device < 4 ORDER BY device ASC LIMIT 5;

--
-- Test ANALYZE.
--
-- First create a separate regular table with the chunk data as a
-- reference of accurate stats. Analyze it and compare with analyze
-- on the original chunk.
--
CREATE TABLE chunk_data (LIKE :chunk);
INSERT INTO chunk_data SELECT * FROM :chunk;
ANALYZE chunk_data;

CREATE VIEW chunk_data_relstats AS
SELECT relname, reltuples, relpages
FROM pg_class
WHERE oid = 'chunk_data'::regclass;

CREATE VIEW chunk_data_attrstats AS
SELECT attname, n_distinct, array_to_string(most_common_vals, E',') AS most_common_vals
FROM pg_stats
WHERE format('%I.%I', schemaname, tablename)::regclass = 'chunk_data'::regclass;

SELECT * FROM chunk_data_relstats;
SELECT * FROM chunk_data_attrstats;

-- Stats on compressed chunk before ANALYZE. Note that this chunk is
-- partially compressed
SELECT relname, reltuples, relpages
FROM pg_class
WHERE oid = :'chunk'::regclass;

SELECT attname, n_distinct, array_to_string(most_common_vals, E',') AS most_common_vals
FROM pg_stats
WHERE format('%I.%I', schemaname, tablename)::regclass = :'chunk'::regclass;

-- ANALYZE directly on chunk
ANALYZE :chunk;

-- Stats after ANALYZE. Show rows that differ. The number of relpages
-- will differ because the chunk is compressed and uses less pages.
SELECT relname, reltuples, relpages
FROM pg_class
WHERE oid = :'chunk'::regclass;

-- There should be no difference in attrstats, so EXCEPT query should
-- show no results
SELECT attname, n_distinct, array_to_string(most_common_vals, E',') AS most_common_vals
FROM pg_stats
WHERE format('%I.%I', schemaname, tablename)::regclass = :'chunk'::regclass
EXCEPT
SELECT * FROM chunk_data_attrstats;

-- ANALYZE also via hypertable root and show that it will
-- recurse to another chunk
ALTER TABLE :chunk2 SET ACCESS METHOD tscompression;
SELECT relname, reltuples, relpages
FROM pg_class
WHERE oid = :'chunk2'::regclass;

SELECT attname, n_distinct, array_to_string(most_common_vals, E',') AS most_common_vals
FROM pg_stats
WHERE format('%I.%I', schemaname, tablename)::regclass = :'chunk2'::regclass;

SELECT count(*) FROM :chunk2;

ANALYZE readings;

SELECT relname, reltuples, relpages
FROM pg_class
WHERE oid = :'chunk2'::regclass;

SELECT attname, n_distinct, array_to_string(most_common_vals, E',') AS most_common_vals
FROM pg_stats
WHERE format('%I.%I', schemaname, tablename)::regclass = :'chunk2'::regclass;

ALTER TABLE :chunk2 SET ACCESS METHOD heap;

-- We should be able to change it back to heap.
-- Compression metadata should be cleaned up
SELECT count(*) FROM _timescaledb_catalog.compression_chunk_size ccs
INNER JOIN _timescaledb_catalog.chunk c ON (c.id = ccs.chunk_id)
WHERE format('%I.%I', c.schema_name, c.table_name)::regclass = :'chunk'::regclass;

SELECT device, count(*) INTO num_rows_before FROM :chunk GROUP BY device;

SELECT format('%I.%I', c2.schema_name, c2.table_name)::regclass AS cchunk
FROM _timescaledb_catalog.chunk c1
INNER JOIN _timescaledb_catalog.chunk c2
ON (c1.compressed_chunk_id = c2.id);
ALTER TABLE :chunk SET ACCESS METHOD heap;
SET timescaledb.enable_transparent_decompression TO true;

-- The compressed chunk should no longer exist
SELECT format('%I.%I', c2.schema_name, c2.table_name)::regclass AS cchunk
FROM _timescaledb_catalog.chunk c1
INNER JOIN _timescaledb_catalog.chunk c2
ON (c1.compressed_chunk_id = c2.id);

SELECT device, count(*) INTO num_rows_after FROM :chunk GROUP BY device;
SELECT device, num_rows_after.count AS after,
	   num_rows_before.count AS before,
	   (num_rows_after.count - num_rows_before.count) AS diff
FROM num_rows_after JOIN num_rows_before USING (device)
WHERE num_rows_after.count != num_rows_before.count;

SELECT count(*) FROM _timescaledb_catalog.compression_chunk_size ccs
INNER JOIN _timescaledb_catalog.chunk c ON (c.id = ccs.chunk_id)
WHERE format('%I.%I', c.schema_name, c.table_name)::regclass = :'chunk'::regclass;

SELECT compress_chunk(:'chunk');

-- A new compressed chunk should be created
SELECT format('%I.%I', c2.schema_name, c2.table_name)::regclass AS cchunk
FROM _timescaledb_catalog.chunk c1
INNER JOIN _timescaledb_catalog.chunk c2
ON (c1.compressed_chunk_id = c2.id);

-- Show same output as first query above but for heap
SELECT * FROM :chunk WHERE device < 4 ORDER BY time, device LIMIT 5;

-- Show access method used on chunk
SELECT c.relname, a.amname FROM pg_class c
INNER JOIN pg_am a ON (c.relam = a.oid)
WHERE c.oid = :'chunk'::regclass;

-- Should give the same result as above
SELECT device, count(*) INTO decomp FROM readings GROUP BY device;

-- Row counts for each device should match, except for the chunk we did inserts on.
SELECT device, orig.count AS orig_count, decomp.count AS decomp_count, (decomp.count - orig.count) AS diff
FROM orig JOIN decomp USING (device) WHERE orig.count != decomp.count;

-- Convert back to tscompression to check that metadata was cleaned up
-- from last time this table used tscompression
ALTER TABLE :chunk SET ACCESS METHOD tscompression;
SET timescaledb.enable_transparent_decompression TO false;

-- Get the chunk's corresponding compressed chunk
SELECT format('%I.%I', c2.schema_name, c2.table_name)::regclass AS cchunk
FROM _timescaledb_catalog.chunk c1
INNER JOIN _timescaledb_catalog.chunk c2
ON (c1.compressed_chunk_id = c2.id) LIMIT 1 \gset

SELECT range_start, range_end
FROM timescaledb_information.chunks
WHERE format('%I.%I', chunk_schema, chunk_name)::regclass = :'chunk'::regclass;

-- insert some new (non-compressed) data into the chunk in order to
-- test recompression
INSERT INTO :chunk (time, location, device, temp, humidity)
SELECT t, ceil(random()*10), ceil(random()*30), random()*40, random()*100
FROM generate_series('2022-06-01 00:06:14'::timestamptz, '2022-06-01 16:59', '5s') t;

-- Check that new data is returned
SELECT * FROM :chunk WHERE time = '2022-06-01 00:06:14'::timestamptz;

-- Want to check that index scans work after recompression, so the
-- query should be an index scan.
EXPLAIN (verbose, costs off)
SELECT * FROM :chunk WHERE time = '2022-06-01 00:06:14'::timestamptz;

-- Show counts in compressed chunk prior to recompression
SELECT sum(_ts_meta_count) FROM :cchunk;
CALL recompress_chunk(:'chunk');

-- Data should be returned even after recompress, but now from the
-- compressed relation
SELECT * FROM :chunk WHERE time = '2022-06-01 00:06:14'::timestamptz;

\set ON_ERROR_STOP 0
-- Can't recompress twice without new non-compressed rows
CALL recompress_chunk(:'chunk');
\set ON_ERROR_STOP 1

-- Compressed count after recompression
SELECT sum(_ts_meta_count) FROM :cchunk;

-- A count on the chunk should return the same count
SELECT count(*) FROM :chunk;
