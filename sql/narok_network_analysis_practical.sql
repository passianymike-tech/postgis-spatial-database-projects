-- ============================================================
-- NAROK COUNTY NETWORK ANALYSIS — pgROUTING PRACTICAL
-- Shortest Path & Service Area Analysis using OSM Road Data
-- Author: Mike Papayai Passiany
-- University of Nairobi — MSc Geospatial Information Science
-- ============================================================
--
-- This practical implements network analysis on OpenStreetMap
-- road data for Narok County, Kenya using PostGIS and pgRouting.
-- The workflow covers:
--   1. Database setup with PostGIS & pgRouting extensions
--   2. OSM data import via osm2pgrouting
--   3. Topology creation and validation
--   4. Dijkstra shortest path routing
--   5. Service area (isochrone) analysis
--   6. Points of interest proximity queries
--
-- Data Source: OpenStreetMap export for Narok County
-- Coordinate System: EPSG:4326 (WGS 84)
-- Study Area: ~36.835°E, -1.276°S (Narok Town)
-- ============================================================

-- ============================================================
-- 1. DATABASE SETUP
-- ============================================================

CREATE DATABASE network_analysis;
\c network_analysis

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- Verify extensions
SELECT PostGIS_Version();
SELECT pgr_version();

-- ============================================================
-- 2. IMPORT OSM DATA
-- ============================================================
-- Run from command line:
-- osm2pgrouting \
--   --f map.osm \
--   --conf mapconfig.xml \
--   --dbname network_analysis \
--   --username postgres \
--   --clean

-- After import, the following tables are created:
-- - ways              (road segments with geometry)
-- - ways_vertices_pgr (network nodes/intersections)
-- - pointsofinterest  (POIs from OSM)

-- ============================================================
-- 3. VERIFY IMPORTED DATA
-- ============================================================

-- Check road network statistics
SELECT
    COUNT(*) AS total_segments,
    SUM(ST_Length(the_geom::geography)) / 1000 AS total_km,
    COUNT(DISTINCT tag_id) AS road_types
FROM ways;

-- Road type breakdown
SELECT
    tag_id,
    COUNT(*) AS segment_count,
    ROUND(SUM(ST_Length(the_geom::geography))::numeric / 1000, 2) AS length_km
FROM ways
GROUP BY tag_id
ORDER BY length_km DESC;

-- Network vertices
SELECT COUNT(*) AS total_nodes FROM ways_vertices_pgr;

-- Points of interest
SELECT
    COUNT(*) AS total_poi
FROM pointsofinterest;

-- Study area extent
SELECT
    ST_XMin(ST_Extent(the_geom))::numeric(10,5) AS min_lon,
    ST_YMin(ST_Extent(the_geom))::numeric(10,5) AS min_lat,
    ST_XMax(ST_Extent(the_geom))::numeric(10,5) AS max_lon,
    ST_YMax(ST_Extent(the_geom))::numeric(10,5) AS max_lat
FROM ways;

-- ============================================================
-- 4. TOPOLOGY VALIDATION
-- ============================================================

-- Analyze graph for dead ends, isolated segments
SELECT pgr_analyzeGraph('ways', 0.00001, 'the_geom', 'gid');

-- Find dead ends (potential data quality issues)
SELECT id, cnt, chk, ein, eout, the_geom
FROM ways_vertices_pgr
WHERE cnt = 1
LIMIT 20;

-- Find isolated segments (disconnected from main network)
SELECT gid, ST_AsText(the_geom)
FROM ways
WHERE source NOT IN (SELECT id FROM ways_vertices_pgr WHERE cnt > 1)
  AND target NOT IN (SELECT id FROM ways_vertices_pgr WHERE cnt > 1)
LIMIT 10;

-- ============================================================
-- 5. DIJKSTRA SHORTEST PATH
-- ============================================================

-- Basic Dijkstra: Find shortest path between vertex 76 and 1005
-- (as shown in QGIS pgRouting Layer panel)
SELECT seq, path_seq, node, edge, cost, agg_cost
FROM pgr_dijkstra(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76,     -- From vertex ID
    1005,   -- To vertex ID
    directed := FALSE
);

-- Dijkstra with geometry output for visualization
SELECT
    d.seq,
    d.path_seq,
    d.node,
    d.edge,
    d.cost,
    d.agg_cost,
    w.the_geom AS geom
FROM pgr_dijkstra(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76, 1005,
    directed := FALSE
) AS d
LEFT JOIN ways AS w ON d.edge = w.gid;

-- Total route distance
SELECT
    ROUND(SUM(cost)::numeric, 2) AS total_distance_m,
    ROUND(SUM(cost)::numeric / 1000, 2) AS total_distance_km
FROM pgr_dijkstra(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76, 1005,
    directed := FALSE
);

-- ============================================================
-- 6. NEAREST VERTEX LOOKUP
-- ============================================================

-- Function to find nearest network vertex to any coordinate
CREATE OR REPLACE FUNCTION find_nearest_vertex(
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION
) RETURNS INTEGER AS $$
    SELECT id::integer
    FROM ways_vertices_pgr
    ORDER BY the_geom <-> ST_SetSRID(ST_MakePoint(lon, lat), 4326)
    LIMIT 1;
$$ LANGUAGE SQL STABLE;

-- Example: Find nearest vertex to Narok Town center
SELECT find_nearest_vertex(35.8713, -1.0878) AS nearest_node;

-- ============================================================
-- 7. COORDINATE-BASED ROUTING
-- ============================================================

-- Route between two coordinates (not vertex IDs)
CREATE OR REPLACE FUNCTION route_between_points(
    start_lon DOUBLE PRECISION, start_lat DOUBLE PRECISION,
    end_lon DOUBLE PRECISION, end_lat DOUBLE PRECISION
) RETURNS TABLE (
    seq INTEGER,
    node BIGINT,
    edge BIGINT,
    cost DOUBLE PRECISION,
    agg_cost DOUBLE PRECISION,
    geom GEOMETRY
) AS $$
BEGIN
    RETURN QUERY
    SELECT d.seq, d.node, d.edge, d.cost, d.agg_cost, w.the_geom
    FROM pgr_dijkstra(
        'SELECT gid AS id, source, target,
                ST_Length(the_geom::geography) AS cost,
                ST_Length(the_geom::geography) AS reverse_cost
         FROM ways',
        find_nearest_vertex(start_lon, start_lat),
        find_nearest_vertex(end_lon, end_lat),
        directed := FALSE
    ) d
    LEFT JOIN ways w ON d.edge = w.gid;
END;
$$ LANGUAGE plpgsql;

-- Example route: Narok Town to a nearby location
SELECT * FROM route_between_points(35.8713, -1.0878, 36.8352, -1.2757);

-- ============================================================
-- 8. SERVICE AREA (ISOCHRONE) ANALYSIS
-- ============================================================

-- Find all edges within a cost threshold (driving distance)
-- Service area: All roads reachable within 5km from vertex 76
SELECT
    d.seq,
    d.node,
    d.edge,
    d.cost,
    d.agg_cost,
    w.the_geom
FROM pgr_drivingDistance(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76,           -- Start vertex
    5000,         -- Max distance in meters
    directed := FALSE
) d
LEFT JOIN ways w ON d.edge = w.gid
WHERE d.edge > 0;

-- Create convex hull of service area for visualization
SELECT ST_ConvexHull(ST_Collect(w.the_geom)) AS service_area_geom
FROM pgr_drivingDistance(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76, 5000,
    directed := FALSE
) d
JOIN ways w ON d.edge = w.gid;

-- ============================================================
-- 9. POI PROXIMITY ANALYSIS
-- ============================================================

-- Find nearest POI to each network vertex
SELECT
    v.id AS vertex_id,
    p.osm_id,
    ST_Distance(v.the_geom::geography, p.the_geom::geography) AS distance_m
FROM ways_vertices_pgr v
CROSS JOIN LATERAL (
    SELECT osm_id, the_geom
    FROM pointsofinterest
    ORDER BY the_geom <-> v.the_geom
    LIMIT 1
) p
WHERE ST_Distance(v.the_geom::geography, p.the_geom::geography) < 500
LIMIT 20;

-- ============================================================
-- 10. EXPORT ROUTE AS GEOJSON
-- ============================================================

-- Export shortest path as GeoJSON for web mapping integration
SELECT json_build_object(
    'type', 'FeatureCollection',
    'features', json_agg(
        json_build_object(
            'type', 'Feature',
            'geometry', ST_AsGeoJSON(w.the_geom)::json,
            'properties', json_build_object(
                'seq', d.seq,
                'cost', ROUND(d.cost::numeric, 2),
                'agg_cost', ROUND(d.agg_cost::numeric, 2)
            )
        )
    )
) AS route_geojson
FROM pgr_dijkstra(
    'SELECT gid AS id, source, target,
            ST_Length(the_geom::geography) AS cost,
            ST_Length(the_geom::geography) AS reverse_cost
     FROM ways',
    76, 1005,
    directed := FALSE
) d
JOIN ways w ON d.edge = w.gid;
