-- ============================================================
-- DRONE SURVEY OPERATIONS DATABASE
-- PostGIS Schema for UAV Flight Planning and No-Fly Zone Management
-- Author: Mike Papayai Passiany
-- ============================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- RESTRICTION ZONES
-- ============================================================

CREATE TABLE restriction_zone_types (
    id SERIAL PRIMARY KEY,
    code VARCHAR(20) UNIQUE NOT NULL,
    name VARCHAR(100) NOT NULL,
    severity INTEGER NOT NULL CHECK (severity BETWEEN 1 AND 5),
    max_altitude_ft INTEGER,
    requires_permit BOOLEAN DEFAULT TRUE,
    description TEXT
);

INSERT INTO restriction_zone_types (code, name, severity, max_altitude_ft, requires_permit, description) VALUES
    ('PROHIBITED', 'Prohibited Zone', 5, 0, TRUE, 'No drone operations allowed under any circumstances'),
    ('RESTRICTED', 'Restricted Zone', 4, 0, TRUE, 'Operations require explicit KCAA authorization'),
    ('CONTROLLED', 'Controlled Zone', 3, 200, TRUE, 'Altitude limited, ATC contact required'),
    ('ADVISORY', 'Advisory Zone', 2, 400, FALSE, 'Flight with caution, awareness required'),
    ('NOTIFICATION', 'Notification Zone', 1, 400, FALSE, 'Standard notification to ATC may suffice');

CREATE TABLE restriction_zones (
    id SERIAL PRIMARY KEY,
    zone_type_id INTEGER REFERENCES restriction_zone_types(id),
    name VARCHAR(255) NOT NULL,
    source_type VARCHAR(50) NOT NULL,  -- airport, military, police, park
    buffer_distance_m INTEGER DEFAULT 0,
    effective_from DATE,
    effective_to DATE,
    is_permanent BOOLEAN DEFAULT TRUE,
    geom GEOMETRY(MultiPolygon, 4326) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_restriction_zones_geom ON restriction_zones USING GIST (geom);
CREATE INDEX idx_restriction_zones_type ON restriction_zones (zone_type_id);
CREATE INDEX idx_restriction_zones_source ON restriction_zones (source_type);

-- ============================================================
-- AIRPORTS / AIRFIELDS
-- ============================================================

CREATE TABLE airports (
    id SERIAL PRIMARY KEY,
    icao_code VARCHAR(4),
    iata_code VARCHAR(3),
    name VARCHAR(255) NOT NULL,
    airport_type VARCHAR(50),  -- international, domestic, airstrip
    elevation_ft INTEGER,
    has_tower BOOLEAN DEFAULT FALSE,
    county VARCHAR(100),
    geom GEOMETRY(Point, 4326) NOT NULL,
    boundary GEOMETRY(Polygon, 4326)
);

CREATE INDEX idx_airports_geom ON airports USING GIST (geom);
CREATE INDEX idx_airports_name ON airports USING GIN (name gin_trgm_ops);

-- ============================================================
-- DRONE OPERATORS AND AIRCRAFT
-- ============================================================

CREATE TABLE operators (
    id SERIAL PRIMARY KEY,
    license_number VARCHAR(50) UNIQUE,
    company_name VARCHAR(255),
    contact_name VARCHAR(255) NOT NULL,
    email VARCHAR(255),
    phone VARCHAR(50),
    kcaa_rpas_cert VARCHAR(100),
    license_valid_until DATE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE drone_aircraft (
    id SERIAL PRIMARY KEY,
    operator_id INTEGER REFERENCES operators(id) ON DELETE CASCADE,
    registration VARCHAR(50) UNIQUE NOT NULL,
    manufacturer VARCHAR(100),
    model VARCHAR(100),
    weight_kg DOUBLE PRECISION,
    category VARCHAR(20) CHECK (category IN ('open', 'specific', 'certified')),
    max_altitude_m INTEGER,
    max_range_km DOUBLE PRECISION,
    has_adsb BOOLEAN DEFAULT FALSE
);

-- ============================================================
-- FLIGHT OPERATIONS
-- ============================================================

CREATE TABLE flight_plans (
    id SERIAL PRIMARY KEY,
    operator_id INTEGER REFERENCES operators(id),
    aircraft_id INTEGER REFERENCES drone_aircraft(id),
    mission_name VARCHAR(255) NOT NULL,
    mission_type VARCHAR(50),  -- survey, mapping, inspection, delivery
    planned_date DATE NOT NULL,
    planned_start_time TIME,
    planned_end_time TIME,
    max_altitude_ft INTEGER NOT NULL,
    status VARCHAR(20) DEFAULT 'draft'
        CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'active', 'completed')),
    flight_area GEOMETRY(Polygon, 4326) NOT NULL,
    takeoff_point GEOMETRY(Point, 4326),
    landing_point GEOMETRY(Point, 4326),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    approved_at TIMESTAMP,
    approved_by VARCHAR(100)
);

CREATE INDEX idx_flight_plans_area ON flight_plans USING GIST (flight_area);
CREATE INDEX idx_flight_plans_date ON flight_plans (planned_date);
CREATE INDEX idx_flight_plans_status ON flight_plans (status);

-- ============================================================
-- SPATIAL QUERIES
-- ============================================================

-- Check if a proposed flight area intersects any restriction zones
CREATE OR REPLACE FUNCTION check_flight_restrictions(flight_plan_id INTEGER)
RETURNS TABLE (
    zone_name VARCHAR,
    zone_type VARCHAR,
    severity INTEGER,
    max_altitude_ft INTEGER,
    requires_permit BOOLEAN,
    overlap_area_km2 DOUBLE PRECISION
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        rz.name,
        rzt.name AS zone_type,
        rzt.severity,
        rzt.max_altitude_ft,
        rzt.requires_permit,
        ROUND(
            ST_Area(
                ST_Intersection(
                    rz.geom::geography,
                    fp.flight_area::geography
                )
            ) / 1000000.0, 4
        )::DOUBLE PRECISION AS overlap_area_km2
    FROM flight_plans fp
    JOIN restriction_zones rz ON ST_Intersects(fp.flight_area, rz.geom)
    JOIN restriction_zone_types rzt ON rz.zone_type_id = rzt.id
    WHERE fp.id = flight_plan_id
        AND (rz.is_permanent OR (
            rz.effective_from <= fp.planned_date 
            AND (rz.effective_to IS NULL OR rz.effective_to >= fp.planned_date)
        ))
    ORDER BY rzt.severity DESC;
END;
$$ LANGUAGE plpgsql;

-- Find nearest airports to a coordinate
CREATE OR REPLACE FUNCTION find_nearest_airports(
    lat DOUBLE PRECISION,
    lon DOUBLE PRECISION,
    radius_km DOUBLE PRECISION DEFAULT 50
)
RETURNS TABLE (
    airport_name VARCHAR,
    icao VARCHAR,
    airport_type VARCHAR,
    distance_km DOUBLE PRECISION
) AS $$
BEGIN
    RETURN QUERY
    SELECT
        a.name,
        a.icao_code,
        a.airport_type,
        ROUND(
            ST_Distance(
                a.geom::geography,
                ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
            ) / 1000.0, 2
        )::DOUBLE PRECISION
    FROM airports a
    WHERE ST_DWithin(
        a.geom::geography,
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        radius_km * 1000
    )
    ORDER BY ST_Distance(
        a.geom::geography,
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography
    );
END;
$$ LANGUAGE plpgsql;

-- Generate buffer zones around airports
CREATE OR REPLACE FUNCTION generate_airport_buffers(airport_id INTEGER)
RETURNS TABLE (
    buffer_label VARCHAR,
    zone_type VARCHAR,
    buffer_geom GEOMETRY
) AS $$
DECLARE
    buffers INTEGER[] := ARRAY[2000, 4000, 6000, 8000];
    labels VARCHAR[] := ARRAY['2km - Restricted', '4km - Controlled', '6km - Advisory', '8km - Awareness'];
    types VARCHAR[] := ARRAY['RESTRICTED', 'CONTROLLED', 'ADVISORY', 'NOTIFICATION'];
    airport_geom GEOMETRY;
BEGIN
    SELECT a.geom INTO airport_geom FROM airports a WHERE a.id = airport_id;
    
    FOR i IN 1..array_length(buffers, 1) LOOP
        buffer_label := labels[i];
        zone_type := types[i];
        buffer_geom := ST_Transform(
            ST_Buffer(
                ST_Transform(airport_geom, 32637),
                buffers[i]
            ),
            4326
        );
        RETURN NEXT;
    END LOOP;
END;
$$ LANGUAGE plpgsql;

-- Daily flight activity summary
CREATE OR REPLACE VIEW daily_flight_summary AS
SELECT
    fp.planned_date,
    COUNT(*) AS total_flights,
    COUNT(DISTINCT fp.operator_id) AS unique_operators,
    SUM(CASE WHEN fp.status = 'completed' THEN 1 ELSE 0 END) AS completed,
    SUM(CASE WHEN fp.status = 'rejected' THEN 1 ELSE 0 END) AS rejected,
    ROUND(AVG(fp.max_altitude_ft)) AS avg_altitude_ft,
    ST_Union(fp.flight_area) AS combined_coverage
FROM flight_plans fp
GROUP BY fp.planned_date
ORDER BY fp.planned_date DESC;
