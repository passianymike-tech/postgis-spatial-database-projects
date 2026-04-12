-- ============================================================
-- NETWORK ANALYSIS WITH pgROUTING
-- Dijkstra Shortest Path for Transport Planning
-- Author: Mike Papayai Passiany
-- ============================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- ============================================================
-- ROAD NETWORK TABLE
-- ============================================================

CREATE TABLE road_network (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    road_type VARCHAR(50),
    surface VARCHAR(50),
    speed_limit INTEGER DEFAULT 50,
    oneway BOOLEAN DEFAULT FALSE,
    source INTEGER,
    target INTEGER,
    cost DOUBLE PRECISION,
    reverse_cost DOUBLE PRECISION,
    length_m DOUBLE PRECISION,
    geom GEOMETRY(LineString, 4326)
);

CREATE INDEX idx_road_network_geom ON road_network USING GIST (geom);
CREATE INDEX idx_road_network_source ON road_network (source);
CREATE INDEX idx_road_network_target ON road_network (target);

-- ============================================================
-- BUILD TOPOLOGY
-- ============================================================

SELECT pgr_createTopology('road_network', 0.00001, 'geom', 'id');

-- Analyze topology for errors
SELECT pgr_analyzeGraph('road_network', 0.00001, 'geom', 'id');

-- ============================================================
-- COST FUNCTIONS
-- ============================================================

-- Update cost based on road type and distance
UPDATE road_network SET
    length_m = ST_Length(geom::geography),
    cost = CASE
        WHEN road_type = 'motorway' THEN ST_Length(geom::geography) * 0.5
        WHEN road_type = 'trunk' THEN ST_Length(geom::geography) * 0.7
        WHEN road_type = 'primary' THEN ST_Length(geom::geography) * 0.8
        WHEN road_type = 'secondary' THEN ST_Length(geom::geography) * 1.0
        WHEN road_type = 'tertiary' THEN ST_Length(geom::geography) * 1.2
        WHEN road_type = 'residential' THEN ST_Length(geom::geography) * 1.5
        ELSE ST_Length(geom::geography) * 2.0
    END,
    reverse_cost = CASE
        WHEN oneway THEN -1
        ELSE CASE
            WHEN road_type = 'motorway' THEN ST_Length(geom::geography) * 0.5
            WHEN road_type = 'trunk' THEN ST_Length(geom::geography) * 0.7
            ELSE ST_Length(geom::geography) * 1.0
        END
    END;

-- ============================================================
-- SHORTEST PATH QUERIES
-- ============================================================

-- Dijkstra: Find shortest path between two points
CREATE OR REPLACE FUNCTION find_shortest_path(
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
DECLARE
    start_node INTEGER;
    end_node INTEGER;
BEGIN
    -- Find nearest source node to start point
    SELECT source INTO start_node FROM road_network
    ORDER BY geom <-> ST_SetSRID(ST_MakePoint(start_lon, start_lat), 4326)
    LIMIT 1;

    -- Find nearest source node to end point
    SELECT source INTO end_node FROM road_network
    ORDER BY geom <-> ST_SetSRID(ST_MakePoint(end_lon, end_lat), 4326)
    LIMIT 1;

    RETURN QUERY
    SELECT r.seq, r.node, r.edge, r.cost, r.agg_cost, rn.geom
    FROM pgr_dijkstra(
        'SELECT id, source, target, cost, reverse_cost FROM road_network',
        start_node, end_node, directed := true
    ) AS r
    LEFT JOIN road_network rn ON r.edge = rn.id;
END;
$$ LANGUAGE plpgsql;

-- Isochrone: Areas reachable within a time/distance threshold
CREATE OR REPLACE FUNCTION generate_isochrone(
    center_lon DOUBLE PRECISION,
    center_lat DOUBLE PRECISION,
    max_cost DOUBLE PRECISION DEFAULT 10000
) RETURNS GEOMETRY AS $$
DECLARE
    center_node INTEGER;
    result GEOMETRY;
BEGIN
    SELECT source INTO center_node FROM road_network
    ORDER BY geom <-> ST_SetSRID(ST_MakePoint(center_lon, center_lat), 4326)
    LIMIT 1;

    SELECT ST_ConcaveHull(ST_Collect(rn.geom), 0.7) INTO result
    FROM pgr_drivingDistance(
        'SELECT id, source, target, cost FROM road_network',
        center_node, max_cost, directed := false
    ) AS dd
    JOIN road_network rn ON dd.edge = rn.id;

    RETURN result;
END;
$$ LANGUAGE plpgsql;
