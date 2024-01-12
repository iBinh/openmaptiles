-- Filter the imported POIs, mostly by blacklisting some subclasses.
CREATE OR REPLACE FUNCTION poi_filter(
    name varchar,
    subclass varchar,
    mapping_key varchar
)
RETURNS BOOLEAN AS $$
SELECT
    CASE
        WHEN mapping_key = 'amenity' THEN
                LOWER(subclass) NOT IN (
                                        'yes', 'no', 'none', 'bench', 'clock', 'drinking_water',
                                        'fountain', 'parking_entrance', 'parking_space', 'photo_booth',
                                        'reception_desk', 'ticket_validator', 'vending_machine',
                                        'waste_disposal', 'water_point'
                )
        WHEN mapping_key = 'healthcare' THEN
                name <> ''
        WHEN mapping_key = 'landuse' THEN
                    name <> '' AND LOWER(subclass) NOT IN ('yes', 'no', 'none')
        WHEN mapping_key = 'leisure' THEN
                LOWER(subclass) NOT IN (
                                        'yes', 'no', 'none', 'common', 'nature_reserve',
                                        'picnic_table', 'slipway', 'swimming_pool', 'track'
                )
        WHEN mapping_key = 'office' THEN
                    name <> '' AND LOWER(subclass) NOT IN ('no', 'none')
        WHEN mapping_key = 'shop' THEN
                LOWER(subclass) NOT IN ('yes', 'no', 'none', 'vacant')
        ELSE
                LOWER(subclass) NOT IN ('yes', 'no', 'none')
        END;
$$ LANGUAGE SQL IMMUTABLE PARALLEL SAFE;

-- Compute the weight of an OSM POI, primarily this function relies on the
-- count of page views for the Wikipedia pages of this POI.
CREATE OR REPLACE FUNCTION poi_display_weight(
    name varchar,
    subclass varchar,
    mapping_key varchar,
    tags hstore
)
RETURNS REAL AS $$
BEGIN
RETURN CASE
           WHEN name <> '' THEN
                   1 - poi_class_rank(poi_class(subclass, mapping_key))::real / 1000
            ELSE
                0.0
END;
END
$$ LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION osm_hash_from_imposm(imposm_id bigint)
RETURNS bigint AS $$
SELECT CASE
           WHEN imposm_id < -1e17 THEN (-imposm_id-1e17) * 10 + 4 -- Relation
           WHEN imposm_id < 0 THEN  (-imposm_id) * 10 + 1 -- Way
           ELSE imposm_id * 10 -- Node
           END::bigint;
$$ LANGUAGE SQL IMMUTABLE PARALLEL SAFE;

CREATE OR REPLACE FUNCTION global_id_from_imposm(imposm_id bigint)
RETURNS TEXT AS $$
SELECT CONCAT(
               'osm:',
               CASE WHEN imposm_id < -1e17 THEN CONCAT('relation:', -imposm_id-1e17)
                    WHEN imposm_id < 0 THEN CONCAT('way:', -imposm_id)
                    ELSE CONCAT('node:', imposm_id)
                   END
           );
$$ LANGUAGE SQL IMMUTABLE PARALLEL SAFE;


CREATE OR REPLACE FUNCTION all_pois(zoom_level integer)
RETURNS TABLE(osm_id bigint, global_id text, geometry geometry, name text, name_en text,
    name_de text, tags hstore, class text, subclass text, agg_stop integer, layer integer,
    level integer, indoor integer, mapping_key text)
AS $$
SELECT osm_id_hash AS osm_id, global_id,
       geometry, NULLIF(name, '') AS name,
       COALESCE(NULLIF(name_en, ''), name) AS name_en,
       COALESCE(NULLIF(name_de, ''), name, name_en) AS name_de,
       tags,
       poi_class(subclass, mapping_key) AS class,
       CASE
           WHEN subclass = 'information'
               THEN NULLIF(information, '')
           WHEN subclass = 'place_of_worship'
               THEN NULLIF(religion, '')
           WHEN subclass IN ('pitch', 'sports_centre')
               THEN NULLIF(sport, '')
           WHEN subclass = 'recycling'
               THEN COALESCE(tags->'recycling_type', 'recycling')
           ELSE subclass
           END AS subclass,
       agg_stop,
       NULLIF(layer, 0) AS layer,
       "level",
       CASE WHEN indoor=TRUE THEN 1 ELSE NULL END as indoor,
       mapping_key
FROM (
         -- etldoc: osm_poi_point ->  layer_poi:z12
         -- etldoc: osm_poi_point ->  layer_poi:z13
         SELECT *,
                osm_hash_from_imposm(osm_id) AS osm_id_hash,
                global_id_from_imposm(osm_id) as global_id
         FROM osm_poi_point
         WHERE zoom_level BETWEEN 12 AND 13
           AND ((subclass='station' AND mapping_key = 'railway')
             OR subclass IN ('halt', 'ferry_terminal'))
         UNION ALL

         -- etldoc: osm_poi_point ->  layer_poi:z14_
         SELECT *,
                osm_hash_from_imposm(osm_id) AS osm_id_hash,
                global_id_from_imposm(osm_id) as global_id
         FROM osm_poi_point
         WHERE zoom_level >= 14
           AND (name <> '' OR (subclass <> 'garden' AND subclass <> 'park'))

         UNION ALL
         -- etldoc: osm_poi_polygon ->  layer_poi:z12
         -- etldoc: osm_poi_polygon ->  layer_poi:z13
         -- etldoc: osm_poi_polygon ->  layer_poi:z14_
         SELECT *,
                NULL::INTEGER AS agg_stop,
                 osm_hash_from_imposm(osm_id) AS osm_id_hash,
                global_id_from_imposm(osm_id) as global_id
         FROM osm_poi_polygon
         WHERE geometry && bbox AND
           CASE
               WHEN zoom_level >= 14 THEN TRUE
               WHEN zoom_level >= 12 AND
                 ((subclass = 'station' AND mapping_key = 'railway')
                 OR subclass IN ('halt', 'ferry_terminal')) THEN TRUE 
               WHEN zoom_level BETWEEN 10 AND 14 THEN
                 subclass IN ('university', 'college') AND
                 POWER(4,zoom_level)
                 -- Compute percentage of the earth's surface covered by this feature (approximately)
                 -- The constant below is 111,842^2 * 180 * 180, where 111,842 is the length of one degree of latitude at the equator in meters.
                 * area / (405279708033600 * COS(ST_Y(ST_Transform(geometry,4326))*PI()/180))
                 -- Match features that are at least 10% of a tile at this zoom
                 > 0.10
               ELSE FALSE END
     ) AS poi_union
ORDER BY "rank"
$$ LANGUAGE SQL STABLE
                PARALLEL SAFE;

-- TODO: Check if the above can be made STRICT -- i.e. if pixel_width could be NULL
