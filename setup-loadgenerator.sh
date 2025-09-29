#!/usr/bin/env bash

OUTPUT_DIR="$PWD/experiment-out"
LUA_FILE="$PWD/workloads/node-failure.lua"
PROFILE="$PWD/load/constant_36rps_15min.csv"
VIRTUAL_USERS=360
TIMEOUT=10000
WARMUP_PAUSE=12
WARMUP_DURATION=120
WARMUP_RPS=3

main() {
    local ip_and_port="$1"
    cd load-generator/tools.descartes.dlim.httploadgenerator || {
        echo "Failed to enter load-generator build directory."
        exit 1
    }
    echo "Building load generator with Maven..."
    if ! mvn clean package; then
        echo "Maven build failed."
        exit 1
    fi

    cd docker || {
        echo "Failed to enter docker directory."
        exit 1
    }

    local lua_file
    lua_file=$(mktemp) || {
        echo "Failed to create temporary lua file."
        exit 1
    }

    local ip=${ip_and_port%:*}
    local port=${ip_and_port#*:}

    if [[ -z "$ip" || -z "$port" ]]; then
        echo "Invalid IP or port retrieved: $ip_and_port"
        exit 1
    fi

    echo "Replacing placeholders in LUA script with IP: $ip and port: $port"
    sed "s/REPLACE_HOSTNAME/$ip/g" "$LUA_FILE" >"$lua_file"
    sed -i "s/REPLACE_PORT/$port/g" "$lua_file"

    echo "Generating Docker Compose configuration..."
    if ! LUA_FILE="$lua_file" \
        OUTPUT_DIR="$OUTPUT_DIR" \
        PROFILE="$PROFILE" \
        VIRTUAL_USERS="$VIRTUAL_USERS" \
        TIMEOUT="$TIMEOUT" \
        WARMUP_DURATION="$WARMUP_DURATION" \
        WARMUP_RPS="$WARMUP_RPS" \
        WARMUP_PAUSE="$WARMUP_PAUSE" \
        docker compose config \
        --output out.yml; then
        echo "Docker Compose config generation failed."
        exit 1
    fi
}

main "$@"
