-- ============================================================
-- ENVIRONMENTAL MONITORING SPATIAL DATABASE
-- PostGIS Schema for Land Use/Land Cover Change Detection
-- Author: Mike Papayai Passiany
-- ============================================================

CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- ============================================================
-- CORE TABLES
-- ============================================================

CREATE TABLE study_areas (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    country VARCHAR(100),
    county VARCHAR(100),
    total_area_ha DOUBLE PRECISION,
    geom GEOMETRY(MultiPolygon, 4326) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_study_areas_geom ON study_areas USING GIST (geom);

CREATE TABLE satellite_imagery (
    id SERIAL PRIMARY KEY,
    study_area_id INTEGER REFERENCES study_areas(id) ON DELETE CASCADE,
    satellite_name VARCHAR(100) NOT NULL,
    sensor VARCHAR(100),
    acquisition_date DATE NOT NULL,
    cloud_cover_pct DOUBLE PRECISION,
    spatial_resolution_m DOUBLE PRECISION,
    bands INTEGER,
    file_path TEXT,
    metadata JSONB,
    geom GEOMETRY(Polygon, 4326),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_imagery_date ON satellite_imagery (acquisition_date);
CREATE INDEX idx_imagery_geom ON satellite_imagery USING GIST (geom);

CREATE TABLE land_cover_classes (
    id SERIAL PRIMARY KEY,
    class_name VARCHAR(100) NOT NULL,
    class_code INTEGER UNIQUE NOT NULL,
    color_hex VARCHAR(7),
    description TEXT
);

-- Insert standard LULC classes
INSERT INTO land_cover_classes (class_name, class_code, color_hex, description) VALUES
    ('Dense Forest', 1, '#006400', 'Areas with continuous tree canopy cover > 70%'),
    ('Barren Land', 2, '#D2B48C', 'Exposed soil, rock, or sand with minimal vegetation'),
    ('Settlement', 3, '#FF0000', 'Built-up areas including residential, commercial, and industrial'),
    ('Grassland', 4, '#90EE90', 'Open areas dominated by grasses and herbaceous plants'),
    ('Planted Farmland', 5, '#FFD700', 'Cultivated agricultural land with active farming');

CREATE TABLE classification_results (
    id SERIAL PRIMARY KEY,
    study_area_id INTEGER REFERENCES study_areas(id) ON DELETE CASCADE,
    imagery_id INTEGER REFERENCES satellite_imagery(id),
    class_id INTEGER REFERENCES land_cover_classes(id),
    epoch_year INTEGER NOT NULL,
    area_sqm DOUBLE PRECISION,
    area_ha DOUBLE PRECISION GENERATED ALWAYS AS (area_sqm / 10000.0) STORED,
    percentage DOUBLE PRECISION,
    geom GEOMETRY(MultiPolygon, 4326),
    classification_method VARCHAR(100) DEFAULT 'Maximum Likelihood',
    overall_accuracy DOUBLE PRECISION,
    kappa_coefficient DOUBLE PRECISION,
    classified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_classification_geom ON classification_results USING GIST (geom);
CREATE INDEX idx_classification_epoch ON classification_results (epoch_year);
CREATE INDEX idx_classification_study_class ON classification_results (study_area_id, class_id);

CREATE TABLE accuracy_assessment (
    id SERIAL PRIMARY KEY,
    study_area_id INTEGER REFERENCES study_areas(id),
    epoch_year INTEGER NOT NULL,
    class_id INTEGER REFERENCES land_cover_classes(id),
    producer_accuracy DOUBLE PRECISION,
    user_accuracy DOUBLE PRECISION,
    overall_accuracy DOUBLE PRECISION,
    kappa_coefficient DOUBLE PRECISION,
    assessed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE ndvi_analysis (
    id SERIAL PRIMARY KEY,
    study_area_id INTEGER REFERENCES study_areas(id) ON DELETE CASCADE,
    epoch_year INTEGER NOT NULL,
    min_ndvi DOUBLE PRECISION,
    max_ndvi DOUBLE PRECISION,
    mean_ndvi DOUBLE PRECISION,
    std_ndvi DOUBLE PRECISION,
    density_class VARCHAR(100),
    area_sqm DOUBLE PRECISION,
    geom GEOMETRY(MultiPolygon, 4326),
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_ndvi_geom ON ndvi_analysis USING GIST (geom);

-- ============================================================
-- CHANGE DETECTION VIEWS
-- ============================================================

CREATE MATERIALIZED VIEW mv_land_cover_changes AS
SELECT
    cr1.study_area_id,
    sa.name AS study_area_name,
    cr1.epoch_year AS from_year,
    cr2.epoch_year AS to_year,
    lc.class_name,
    lc.color_hex,
    cr1.area_sqm AS from_area_sqm,
    cr2.area_sqm AS to_area_sqm,
    cr2.area_sqm - cr1.area_sqm AS area_change_sqm,
    ROUND(((cr2.area_sqm - cr1.area_sqm) / NULLIF(cr1.area_sqm, 0) * 100)::numeric, 2) AS percent_change
FROM classification_results cr1
JOIN classification_results cr2
    ON cr1.study_area_id = cr2.study_area_id
    AND cr1.class_id = cr2.class_id
JOIN land_cover_classes lc ON cr1.class_id = lc.id
JOIN study_areas sa ON cr1.study_area_id = sa.id
WHERE cr2.epoch_year > cr1.epoch_year
ORDER BY cr1.study_area_id, cr1.epoch_year, lc.class_name;

CREATE MATERIALIZED VIEW mv_epoch_summary AS
SELECT
    cr.study_area_id,
    sa.name AS study_area_name,
    cr.epoch_year,
    SUM(cr.area_sqm) AS total_area_sqm,
    COUNT(DISTINCT cr.class_id) AS num_classes,
    MAX(cr.overall_accuracy) AS overall_accuracy,
    MAX(cr.kappa_coefficient) AS kappa_coefficient
FROM classification_results cr
JOIN study_areas sa ON cr.study_area_id = sa.id
GROUP BY cr.study_area_id, sa.name, cr.epoch_year
ORDER BY cr.study_area_id, cr.epoch_year;

-- ============================================================
-- SPATIAL QUERY FUNCTIONS
-- ============================================================

-- Function: Get area of intersection between two geometries
CREATE OR REPLACE FUNCTION calculate_intersection_area(
    geom1 GEOMETRY, geom2 GEOMETRY
) RETURNS DOUBLE PRECISION AS $$
BEGIN
    RETURN ST_Area(ST_Intersection(geom1, geom2)::geography);
END;
$$ LANGUAGE plpgsql;

-- Function: Get LULC stats for a given point location and radius
CREATE OR REPLACE FUNCTION get_lulc_stats_at_point(
    lon DOUBLE PRECISION,
    lat DOUBLE PRECISION,
    radius_m DOUBLE PRECISION DEFAULT 5000,
    target_year INTEGER DEFAULT 2024
) RETURNS TABLE (
    class_name VARCHAR,
    area_sqm DOUBLE PRECISION,
    percentage DOUBLE PRECISION
) AS $$
BEGIN
    RETURN QUERY
    SELECT lc.class_name, cr.area_sqm, cr.percentage
    FROM classification_results cr
    JOIN land_cover_classes lc ON cr.class_id = lc.id
    WHERE cr.epoch_year = target_year
    AND ST_DWithin(
        cr.geom::geography,
        ST_SetSRID(ST_MakePoint(lon, lat), 4326)::geography,
        radius_m
    )
    ORDER BY cr.area_sqm DESC;
END;
$$ LANGUAGE plpgsql;

-- ============================================================
-- SAMPLE DATA: Eastern Mau Forest Reserve
-- ============================================================

INSERT INTO study_areas (name, description, country, county, total_area_ha, geom)
VALUES (
    'Eastern Mau Forest Reserve',
    'Critical ecological asset in Kenya Great Rift Valley spanning approximately 155,087 hectares. Major water catchment area and biodiversity hotspot.',
    'Kenya',
    'Nakuru/Narok',
    155087,
    ST_GeomFromText('MULTIPOLYGON(((35.58 -0.42, 35.92 -0.42, 35.92 -0.75, 35.58 -0.75, 35.58 -0.42)))', 4326)
);

-- Classification data from the 40-year study (1984-2024)
-- Dense Forest
INSERT INTO classification_results (study_area_id, class_id, epoch_year, area_sqm, percentage, overall_accuracy, kappa_coefficient) VALUES
    (1, 1, 1984, 154200000, 25.7, 93.45, 0.8701),
    (1, 1, 1986, 160204200, 25.2, 94.24, 0.8902),
    (1, 1, 1995, 175914200, 26.7, 91.67, 0.8503),
    (1, 1, 2002, 145938009, 22.6, 96.67, 0.9304),
    (1, 1, 2014, 142651042, 22.0, 93.94, 0.8336),
    (1, 1, 2024, 165524411, 25.2, 91.50, 0.8313);

-- Barren Land
INSERT INTO classification_results (study_area_id, class_id, epoch_year, area_sqm, percentage, overall_accuracy, kappa_coefficient) VALUES
    (1, 2, 1984, 171800000, 28.6, 93.45, 0.8701),
    (1, 2, 1986, 169497600, 26.7, 94.24, 0.8902),
    (1, 2, 1995, 117704933, 17.9, 91.67, 0.8503),
    (1, 2, 2002, 155133504, 24.0, 96.67, 0.9304),
    (1, 2, 2014, 160424232, 24.8, 93.94, 0.8336),
    (1, 2, 2024, 168567040, 25.5, 91.50, 0.8313);
