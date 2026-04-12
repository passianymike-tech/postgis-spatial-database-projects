# PostGIS Spatial Database Projects

A collection of spatial database design, optimization, and analysis projects using **PostgreSQL/PostGIS**. These projects demonstrate expertise in spatial data modeling, geospatial queries, network analysis, and database-driven GIS workflows for real-world applications.

## Projects

### 1. Geospatial Data Warehouse for Environmental Monitoring
**Use Case**: Multi-agency environmental monitoring system for land use/land cover tracking.

- Designed a normalized spatial database schema supporting multi-temporal satellite imagery metadata, field survey data, and administrative boundaries.
- Implemented PostGIS spatial indexing (GiST) for optimized spatial queries across 155,000+ hectares of forest reserve data.
- Built materialized views for pre-computed change detection statistics.
- **Tools**: PostgreSQL 15, PostGIS 3.3, pgAdmin, ArcGIS Pro (database connection)

### 2. Network Analysis for Transport Routing (Dijkstra Algorithm)
**Use Case**: Optimal route computation for emergency response and infrastructure planning.

- Implemented pgRouting extension with Dijkstra's shortest path algorithm on road network datasets.
- Loaded and topologized OpenStreetMap road networks into PostGIS using `osm2pgrouting`.
- Created custom cost functions incorporating road type, distance, and elevation data.
- **Tools**: PostgreSQL, PostGIS, pgRouting, QGIS, Python (psycopg2)

### 3. Land Parcel Management System (LIMS)
**Use Case**: Cadastral land information management for county governments.

- Designed a relational database with spatial extensions for parcel geometry, ownership records, and land use zoning.
- Implemented spatial triggers for automatic area calculation and topology validation.
- Built REST API endpoints using Python (Flask + psycopg2) for web-based parcel querying.
- **Tools**: PostgreSQL, PostGIS, Python, Flask, Leaflet.js

### 4. Real Estate Suitability Analysis Database
**Use Case**: Multi-criteria land suitability analysis for real estate development.

- Integrated elevation (DEM), hydrological, soil, and infrastructure proximity data into a unified spatial database.
- Developed stored procedures for weighted overlay analysis using PostGIS raster functions.
- Generated suitability scores as materialized views for rapid dashboard consumption.
- **Tools**: PostgreSQL, PostGIS (raster), ArcGIS Pro, Power BI

### 5. Hospitality Management Geospatial Database
**Use Case**: Location-based services and spatial resource management for hotel operations.

- Designed comprehensive RDBMS with spatial extensions for facility management, event tracking, and guest services.
- Implemented spatial queries for proximity-based amenity recommendations.
- **Tools**: PostgreSQL, PostGIS, SQL, ER Modeling

## Database Schema Sample

```sql
-- Environmental Monitoring Schema
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_raster;

CREATE TABLE study_areas (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    geom GEOMETRY(MultiPolygon, 4326) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_study_areas_geom ON study_areas USING GIST (geom);

CREATE TABLE land_cover_classes (
    id SERIAL PRIMARY KEY,
    class_name VARCHAR(100) NOT NULL,
    class_code INTEGER UNIQUE NOT NULL,
    color_hex VARCHAR(7),
    description TEXT
);

CREATE TABLE classification_results (
    id SERIAL PRIMARY KEY,
    study_area_id INTEGER REFERENCES study_areas(id),
    class_id INTEGER REFERENCES land_cover_classes(id),
    epoch_year INTEGER NOT NULL,
    area_sqm DOUBLE PRECISION,
    percentage DOUBLE PRECISION,
    geom GEOMETRY(MultiPolygon, 4326),
    accuracy DOUBLE PRECISION,
    kappa_coefficient DOUBLE PRECISION,
    classified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_classification_geom ON classification_results USING GIST (geom);
CREATE INDEX idx_classification_epoch ON classification_results (epoch_year);

-- Change Detection View
CREATE MATERIALIZED VIEW land_cover_changes AS
SELECT
    cr1.study_area_id,
    cr1.epoch_year AS from_year,
    cr2.epoch_year AS to_year,
    lc.class_name,
    cr2.area_sqm - cr1.area_sqm AS area_change_sqm,
    ROUND(((cr2.area_sqm - cr1.area_sqm) / NULLIF(cr1.area_sqm, 0) * 100)::numeric, 2) AS percent_change
FROM classification_results cr1
JOIN classification_results cr2
    ON cr1.study_area_id = cr2.study_area_id
    AND cr1.class_id = cr2.class_id
    AND cr2.epoch_year = cr1.epoch_year + (
        SELECT MIN(b.epoch_year) - cr1.epoch_year
        FROM classification_results b
        WHERE b.epoch_year > cr1.epoch_year
        AND b.study_area_id = cr1.study_area_id
    )
JOIN land_cover_classes lc ON cr1.class_id = lc.id
ORDER BY cr1.study_area_id, cr1.epoch_year, lc.class_name;
```

## Network Analysis Sample

```sql
-- pgRouting: Dijkstra Shortest Path
CREATE EXTENSION IF NOT EXISTS pgrouting;

-- Create topology from road network
SELECT pgr_createTopology('road_network', 0.00001, 'geom', 'id');

-- Find shortest path between two nodes
SELECT seq, id1 AS node, id2 AS edge, cost, geom
FROM pgr_dijkstra(
    'SELECT id, source, target, st_length(geom::geography) AS cost FROM road_network',
    (SELECT source FROM road_network ORDER BY geom <-> ST_SetSRID(ST_MakePoint(35.85, -0.35), 4326) LIMIT 1),
    (SELECT source FROM road_network ORDER BY geom <-> ST_SetSRID(ST_MakePoint(35.95, -0.45), 4326) LIMIT 1),
    directed := false
) AS route
JOIN road_network ON route.id2 = road_network.id;
```

## Technologies
- PostgreSQL 15 / PostGIS 3.3
- pgRouting
- Python (psycopg2, SQLAlchemy, GeoAlchemy2)
- ArcGIS Pro (Enterprise Geodatabase connection)
- QGIS (DB Manager)
- pgAdmin 4

## Author
**Mike Papayai Passiany**
MSc Geographic Information Systems — University of Nairobi
[LinkedIn](https://www.linkedin.com/in/59b641a2/) | [Portfolio](https://papayai.droneverse.pro/)
