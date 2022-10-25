#!/bin/bash

## This file does the following
## i. Builds the Docker image of RonDB
## i. Generates a config.ini & my.cnf file
## i. Creates docker-compose file
## i. Runs docker-compose

set -e

function print_usage() {
    cat <<EOF
Usage:
  $0    [-v     --rondb-version]
        [-g     --glibc-version]
        [-m     --num-mgm-nodes]
        [-d     --num-data-nodes]
        [-r     --replication-factor]
        [-my    --num-mysql-nodes]
        [-a     --num-api-nodes]
        [-det   --detached]
EOF
}

if [ -z "$1" ]; then
    print_usage
    exit 0
fi

#######################
#### CLI Arguments ####
#######################

# Defaults
NUM_MGM_NODES=1
NUM_DATA_NODES=1
NUM_MYSQL_NODES=0
NUM_API_NODES=0
REPLICATION_FACTOR=1

POSITIONAL=()
while [[ $# -gt 0 ]]; do
    key="$1"

    case $key in
    -v | --rondb-version)
        RONDB_VERSION="$2"
        shift # past argument
        shift # past value
        ;;
    -g | --glibc-version)
        GLIBC_VERSION="$2"
        shift # past argument
        shift # past value
        ;;
    -m | --num-mgm-nodes)
        NUM_MGM_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -d | --num-data-nodes)
        NUM_DATA_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -r | --replication-factor)
        REPLICATION_FACTOR="$2"
        shift # past argument
        shift # past value
        ;;
    -my | --num-mysql-nodes)
        NUM_MYSQL_NODES="$2"
        shift # past argument
        shift # past value
        ;;
    -a | --num-api-nodes)
        NUM_API_NODES="$2"
        shift # past argument
        shift # past value
        ;;

    -det | --detached)
        DOCKER_COMPOSE_DETACHED="-d"
        shift # past argument
        ;;

    *)                     # unknown option
        POSITIONAL+=("$1") # save it in an array for later
        shift              # past argument
        ;;
    esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters

echo "RonDB version                             = ${RONDB_VERSION}"
echo "Glibc version                             = ${GLIBC_VERSION}"
echo "Number of management nodes                = ${NUM_MGM_NODES}"
echo "Number of data nodes                      = ${NUM_DATA_NODES}"
echo "Replication factor                        = ${REPLICATION_FACTOR}"
echo "Number of mysql nodes                     = ${NUM_MYSQL_NODES}"
echo "Number of api nodes                       = ${NUM_API_NODES}"
echo "Running docker-compose in detached mode   = ${DOCKER_COMPOSE_DETACHED}"

if [[ -n $1 ]]; then
    echo "Last line of file specified as non-opt/last argument:"
    tail -1 "$1"
fi

if [ $NUM_MGM_NODES -lt 1 ]; then
    echo "At least 1 mgmd is required"
    exit 1
elif [ $REPLICATION_FACTOR -lt 1 ]; then
    echo "The replication factor has to be at least 1"
    exit 1
elif [ $NUM_DATA_NODES -lt 1 ]; then
    echo "At least 1 ndbd is required"
    exit 1
fi

MOD_NDBDS=$(($NUM_DATA_NODES % $REPLICATION_FACTOR))
if [ $MOD_NDBDS -ne 0 ]; then
    echo "The number of data nodes needs to be a multiple of the replication factor"
    exit 1
fi

# https://stackoverflow.com/a/246128/9068781
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)

AUTOGENERATED_FILES_DIR="$SCRIPT_DIR/autogenerated_files"
mkdir -p $AUTOGENERATED_FILES_DIR

FILE_SUFFIX="v${RONDB_VERSION}_m${NUM_MGM_NODES}_d${NUM_DATA_NODES}_r${REPLICATION_FACTOR}_my${NUM_MYSQL_NODES}_api${NUM_API_NODES}"
DOCKER_COMPOSE_FILEPATH="$AUTOGENERATED_FILES_DIR/docker_compose_$FILE_SUFFIX.yml"
CONFIG_INI_FILEPATH="$AUTOGENERATED_FILES_DIR/config_$FILE_SUFFIX.ini"
MY_CNF_FILEPATH="$AUTOGENERATED_FILES_DIR/my_$FILE_SUFFIX.cnf"

#######################
#######################
#######################

echo "Building RonDB Docker image for local platform"

RONDB_IMAGE_NAME="rondb:$RONDB_VERSION"
docker buildx build . \
    --tag $RONDB_IMAGE_NAME \
    --build-arg RONDB_VERSION=$RONDB_VERSION \
    --build-arg GLIBC_VERSION=$GLIBC_VERSION

#######################
#######################
#######################

echo "Loading templates"

CONFIG_INI_TEMPLATE=$(cat ./resources/config_templates/config.ini)
CONFIG_INI_MGMD_TEMPLATE=$(cat ./resources/config_templates/config_mgmd.ini)
CONFIG_INI_NDBD_TEMPLATE=$(cat ./resources/config_templates/config_ndbd.ini)
CONFIG_INI_MYSQLD_TEMPLATE=$(cat ./resources/config_templates/config_mysqld.ini)
CONFIG_INI_API_TEMPLATE=$(cat ./resources/config_templates/config_api.ini)

MY_CNF_TEMPLATE=$(cat ./resources/config_templates/my.cnf)

# Doing restart on-failure for the agent upgrade; we return a failure there
RONDB_DOCKER_COMPOSE_TEMPLATE="

    <insert-service-name>:
      image: $RONDB_IMAGE_NAME
      container_name: <insert-service-name>
"

VOLUMES_FIELD="
      volumes:"

ENV_FIELD="
      environment:"

# We add volumes to the data dir for debugging purposes
ENV_VAR_TEMPLATE="
      - %s=%s"

# Bind config.ini to mgmd containers
BIND_CONFIG_INI_TEMPLATE="
      - type: bind
        source: $CONFIG_INI_FILEPATH
        target: /srv/hops/mysql-cluster/config.ini"

# Bind my.cnf to mgmd containers
BIND_MY_CNF_TEMPLATE="
      - type: bind
        source: $MY_CNF_FILEPATH
        target: /srv/hops/mysql-cluster/my.cnf"

# We add volumes to the data dir for debugging purposes
VOLUME_DATA_DIR_TEMPLATE="
      - %s:/srv/hops/mysql-cluster/%s"

COMMAND_TEMPLATE="
      command: [ %s ]"

#######################
#######################
#######################

echo "Filling out templates"

CONFIG_INI=$(printf "$CONFIG_INI_TEMPLATE" "$REPLICATION_FACTOR")
MGM_CONNECTION_STRING=''
VOLUMES=()
BASE_DOCKER_COMPOSE_FILE="version: '3.8'

services:"

for CONTAINER_NUM in $(seq $NUM_MGM_NODES); do
    NODE_ID=$((65 + $(($CONTAINER_NUM - 1))))

    template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
    SERVICE_NAME="mgmd_$CONTAINER_NUM"
    template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
    command=$(printf "$COMMAND_TEMPLATE" "\"ndb_mgmd\", \"--ndb-nodeid=$NODE_ID\", \"--initial\"")
    template+="$command"

    # mgmds require very little resources
    template+="
      deploy:
        resources:
          limits:
            cpus: '0.2'
            memory: 50M
          reservations:
            memory: 20M"

    template+="$VOLUMES_FIELD"
    template+="$BIND_CONFIG_INI_TEMPLATE"

    VOLUME_NAME="dataDir_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "mgmd")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    VOLUME_NAME="logDir_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "log")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    BASE_DOCKER_COMPOSE_FILE+="$template"

    # NodeId, HostName, PortNumber, NodeActive, ArbitrationRank
    SLOT=$(printf "$CONFIG_INI_MGMD_TEMPLATE" "$NODE_ID" "$SERVICE_NAME" "1186" "1" "2")
    CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")

    MGM_CONNECTION_STRING+="$SERVICE_NAME:1186,"
done

# We're not bothering with inactive ndbds here
NUM_NODE_GROUPS=$(($NUM_DATA_NODES / $REPLICATION_FACTOR))
for CONTAINER_NUM in $(seq $NUM_DATA_NODES); do
    NODE_ID=$CONTAINER_NUM

    template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
    SERVICE_NAME="ndbd_$CONTAINER_NUM"
    template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
    command=$(printf "$COMMAND_TEMPLATE" "\"ndbmtd\", \"--ndb-nodeid=$NODE_ID\", \"--initial\", \"--ndb-connectstring=$MGM_CONNECTION_STRING\"")
    template+="$command"
    # template+="
    #   restart: always"

    # Make sure these memory boundaries are allowed in Docker settings!
    # To check whether they are being used use `docker stats`
    # We need this amount of memory during start; after it is done, only
    # around 2500M are used.
    template+="
      deploy:
        resources:
          limits:
            cpus: '2'
            memory: 7000M
          reservations:
            memory: 7000M"

    template+="$VOLUMES_FIELD"

    VOLUME_NAME="dataDir_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "ndb_data")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    VOLUME_NAME="logDir_$SERVICE_NAME"
    volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "log")
    template+="$volume"
    VOLUMES+=("$VOLUME_NAME")

    BASE_DOCKER_COMPOSE_FILE+="$template"

    NODE_GROUP=$(($CONTAINER_NUM % $NUM_NODE_GROUPS))
    # NodeId, NodeGroup, NodeActive, HostName, ServerPort, FileSystemPath (NodeId)
    SLOT=$(printf "$CONFIG_INI_NDBD_TEMPLATE" "$NODE_ID" "$NODE_GROUP" "1" "$SERVICE_NAME" "11860" "$NODE_ID")
    CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")
done

# TODO: Add env variable so that only one mysqld container runs the initialisation
SLOTS_PER_CONTAINER=2 # Cannot scale out a lot on a single machine
if [ $NUM_MYSQL_NODES -gt 0 ]; then
    for CONTAINER_NUM in $(seq $NUM_MYSQL_NODES); do
        template="$RONDB_DOCKER_COMPOSE_TEMPLATE"
        SERVICE_NAME="mysqld_$CONTAINER_NUM"
        template=$(echo "$template" | sed "s/<insert-service-name>/$SERVICE_NAME/g")
        command=$(printf "$COMMAND_TEMPLATE" "\"mysqld\"")
        template+="$command"

        # Make sure these memory boundaries are allowed in Docker settings!
        # To check whether they are being used use `docker stats`
        template+="
      deploy:
        resources:
          limits:
            cpus: '2'
            memory: 1400M
          reservations:
            memory: 650M"

        template+="$VOLUMES_FIELD"
        template+="$BIND_MY_CNF_TEMPLATE"

        VOLUME_NAME="dataDir_$SERVICE_NAME"
        volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "mysqld")
        template+="$volume"
        VOLUMES+=("$VOLUME_NAME")

        # This is for debugging
        VOLUME_NAME="mysqlFilesDir_$SERVICE_NAME"
        volume=$(printf "$VOLUME_DATA_DIR_TEMPLATE" "$VOLUME_NAME" "mysql-files")
        template+="$volume"
        VOLUMES+=("$VOLUME_NAME")

        # Can add the following env vars to the mysqld containers:
        # MYSQL_ROOT_PASSWORD
        # MYSQL_DATABASE
        # MYSQL_USER
        # MYSQL_PASSWORD

        template+="$ENV_FIELD"
        env_var=$(printf "$ENV_VAR_TEMPLATE" "MYSQL_ALLOW_EMPTY_PASSWORD" "true")
        template+="$env_var"

        BASE_DOCKER_COMPOSE_FILE+="$template"

        NODE_ID_OFFSET=$(($CONTAINER_NUM * $SLOTS_PER_CONTAINER))
        for SLOT_NUM in $(seq $SLOTS_PER_CONTAINER); do
            NODE_ID=$((67 + $NODE_ID_OFFSET + $(($SLOT_NUM - 1))))
            # NodeId, NodeActive, ArbitrationRank, HostName
            SLOT=$(printf "$CONFIG_INI_MYSQLD_TEMPLATE" "$NODE_ID" "1" "1" "$SERVICE_NAME")
            CONFIG_INI=$(printf "%s\n\n%s" "$CONFIG_INI" "$SLOT")
        done
    done
fi

# Append volumes to end of file
BASE_DOCKER_COMPOSE_FILE+="

volumes:"

for VOLUME in "${VOLUMES[@]}"; do
    BASE_DOCKER_COMPOSE_FILE+="
    $VOLUME:"
done

BASE_DOCKER_COMPOSE_FILE+="
"

#######################
#######################
#######################

echo "Writing data to files"

if [ "$NUM_MYSQL_NODES" -gt 0 ]; then
    echo "Writing my.cnf"
    MY_CNF=$(printf "$MY_CNF_TEMPLATE" "$SLOTS_PER_CONTAINER" "$MGM_CONNECTION_STRING")
    echo "$MY_CNF" >$MY_CNF_FILEPATH
fi

echo "$BASE_DOCKER_COMPOSE_FILE" >$DOCKER_COMPOSE_FILEPATH
echo "$CONFIG_INI" >$CONFIG_INI_FILEPATH

# Remove previous volumes
docker-compose -f $DOCKER_COMPOSE_FILEPATH -p "rondb_$FILE_SUFFIX" down -v
# Run fresh setup
docker-compose -f $DOCKER_COMPOSE_FILEPATH -p "rondb_$FILE_SUFFIX" up $DOCKER_COMPOSE_DETACHED
