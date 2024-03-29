#! /bin/bash
# to run this script you need openmaptiles-tools
# and to pass the env var CONFIG_DIR to the script

[[ -z ${CONFIG_DIR} ]] && echo "ERROR: set CONFIG_DIR to the kartotherian_config path" && exit 1

set -e

for tiles in 'base' 'poi'; do
    tileset="openmaptiles_$tiles.yaml"


    # no sql and no mapping for the lite tiles
    generate-sql $tileset > $CONFIG_DIR/imposm/generated_$tiles.sql
    generate-imposm3 $tileset > $CONFIG_DIR/imposm/generated_mapping_$tiles.yaml

    # Use "single id space" to store osm_id as integers in a deterministic way
    # And be able to transform it back to string with osm type (node/way/relation)
    echo 'use_single_id_space: true' >> $CONFIG_DIR/imposm/generated_mapping_$tiles.yaml
    generate-tm2source $tileset  --host="localhost" --port=5432 --database="gis" --user="nice_user" --password="nice_password" > $CONFIG_DIR/tilerator/data_tm2source_$tiles.yml

done
