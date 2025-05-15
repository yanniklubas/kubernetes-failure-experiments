#!/usr/bin/env bash
set -eou pipefail

# GENERAL CONFIGURATION
SERVER_IP="10.1.3.40"
LOCAL_STORAGE_YAML="robot-local-storage.yml"
STANDARD_STORAGE_YAML="robot-standard-storage.yml"
EXPERIMENT_MODE="pod" # "node" or "pod"

# NODE FAILURE CONFIGURATION
NODE_FAILURE_IP="10.1.3.38"
NODE_FAILURE_TIME=30
NODE_FAILURE_DURATION=120

# POD FAILURE CONFIGURATION
POD_FAILURE_NAME="catalogue"
POD_FAILURE_TIME=60

# LOADGENERATOR CONFIGURATION
LUA_FILE="$PWD/workloads/cart-add.lua"
PROFILE="$PWD/load/constant_12rps_3min.csv"
TIMEOUT=8000
VIRTUAL_USERS=96
WARMUP_DURATION=120
WARMUP_RPS=3
WARMUP_PAUSE=10

__exec_remote_commands() {
    local user="$1"
    shift
    local ip="$1"
    shift
    local cmds=""
    while IFS= read -r cmd; do
        cmds+="$cmd; "
    done < <(printf "%s\n" "$@")
    ssh "$user"@"$ip" bash <<<"$cmds"
}

hostname_to_ip() {
    kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

now() {
    date +%s
}

log_info() {
    printf "[INFO]: %s\n" "$@" >&2
}

save_config() {
    local out="$OUTPUT_DIR/config.yml"
    printf "profile: %s\n" "$PROFILE" >"$out"
    {
        printf "timeout: %s\n" "$TIMEOUT"
        printf "virtual_users: %s\n" "$VIRTUAL_USERS"
        printf "warmup_duration: %s\n" "$WARMUP_DURATION"
        printf "warmup_rps: %s\n" "$WARMUP_RPS"
        printf "warmup_pause: %s\n" "$WARMUP_PAUSE"
        printf "server: %s\n" "$SERVER_IP"
    } >>"$out"
    case "$EXPERIMENT_MODE" in
    "node")
        {
            printf "failure_ip: %s\n" "$NODE_FAILURE_IP"
            printf "failure_time: %s\n" "$NODE_FAILURE_TIME"
            printf "failure_duration: %s\n" "$NODE_FAILURE_DURATION"
        } >>"$out"
        ;;
    "pod")
        {
            printf "pod_failure_name: %s\n" "$POD_FAILURE_NAME"
            printf "failure_time: %s\n" "$POD_FAILURE_TIME"
        } >>"$out"
        ;;
    *)
        echo "INVALID EXPERIMENT MODE $EXPERIMENT_MODE" >&2
        exit 1
        ;;
    esac
}

backup_dir() {
    local dir="$1"
    local counter=1

    if [[ -d "$dir" ]]; then
        local backup="$dir-$counter"
        while [[ -d "$backup" ]]; do
            ((counter++))
            backup="$dir-$counter"
        done
        mv "$dir" "$backup"
    fi
}

start_robot_shop() {
    local remote_cmds=(
        "if [ ! -d robot-shop ]; then git clone https://github.com/saurabhjha1/robot-shop.git \$HOME/robot-shop; fi"
        "helm uninstall robot-shop"
        "kubectl delete pod rabbitmq-server-0 --wait"
        "kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq --type json --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]'"
        "kubectl delete pvc --all"
        "kubectl delete pv --all"
        "sleep 5"
        "kubectl apply -f \$HOME/$LOCAL_STORAGE_YAML -f \$HOME/$STANDARD_STORAGE_YAML"
        "helm install robot-shop --set nodeport=true \$HOME/robot-shop/K8s/helm/"
        "kubectl wait --for=condition=Ready pod --all --timeout -1s"
        "kubectl delete deployments.apps load"
    )

    __exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}"
}

start_robot_shop_local() {
    if [ ! -d robot-shop ]; then
        git clone https://github.com/yanniklubas/robot-shop.git "$HOME/robot-shop"
    fi

    local remote_cmds=(
        "hostname"
    )
    local hostname
    hostname=$(__exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}")

    local remote_cmds=(
        "mkdir -p /data/robot-local"
        "mkdir -p /data/robot-standard"
    )
    __exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}"

    local local_storage
    local_storage=$(mktemp)
    sed "s/REPLACE_HOSTNAME/$hostname/g" "$HOME/robot-shop/K8s/$LOCAL_STORAGE_YAML" >"$local_storage"
    local standard_storage
    standard_storage=$(mktemp)
    sed "s/REPLACE_HOSTNAME/$hostname/g" "$HOME/robot-shop/K8s/$STANDARD_STORAGE_YAML" >"$standard_storage"

    if helm list | grep "robot-shop"; then
        helm uninstall robot-shop
        kubectl delete pod rabbitmq-server-0 --wait
        kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]'
        kubectl delete pvc --all
        kubectl delete pv --all
        sleep 5
    fi
    kubectl apply -f "$HOME/robot-shop/K8s/local-storage-class.yml"
    kubectl apply -f "$local_storage" -f "$standard_storage"
    helm install robot-shop "$HOME/robot-shop/K8s/helm/"
    kubectl wait --for=condition=Ready pod --all --timeout -1s
    kubectl delete deployments.apps load
    rm "$local_storage"
    rm "$standard_storage"
}

start_loadgenerator() {
    if [ ! -d "load-generator" ]; then
        git clone https://github.com/yanniklubas/HTTP-Load-Generator.git "load-generator"
    fi
    (
        cd load-generator/tools.descartes.dlim.httploadgenerator/docker
        local lua_file
        lua_file=$(mktemp)
        local ip_and_port
        ip_and_port=$(kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}:{.spec.ports[?(@.name=="http")].port}')
        local ip=${ip_and_port%:*}
        local port=${ip_and_port#*:}
        sed "s/REPLACE_HOSTNAME/$ip/g" "$LUA_FILE" >"$lua_file"
        sed -i "s/REPLACE_PORT/$port/g" "$lua_file"
        LUA_FILE="$lua_file" \
            OUTPUT_DIR="$OUTPUT_DIR" \
            PROFILE="$PROFILE" \
            VIRTUAL_USERS="$VIRTUAL_USERS" \
            TIMEOUT="$TIMEOUT" \
            WARMUP_DURATION="$WARMUP_DURATION" \
            WARMUP_RPS="$WARMUP_RPS" \
            WARMUP_PAUSE="$WARMUP_PAUSE" \
            docker compose up \
            --force-recreate --wait
        rm "$lua_file"
    )
}

inject_node_failure() {
    local start="$1"
    local sleep_secs
    local now_ts
    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + NODE_FAILURE_TIME))
    now_ts=$(now)
    sleep_secs=$((wake_ts - now_ts))
    local remote_cmds=(
        "sleep $sleep_secs"
        "sudo systemctl stop kubelet.service containerd.service"
        "pgrep containerd | xargs sudo kill"
        "sleep $NODE_FAILURE_DURATION"
        "sudo systemctl start kubelet.service containerd.service"
    )

    log_info "Sleeping for ${sleep_secs}s"
    __exec_remote_commands "$USER" "$NODE_FAILURE_IP" "${remote_cmds[@]}"
    log_info "Injected Failure"
}

inject_pod_failure() {
    local start="$1"
    local sleep_secs
    local now_ts
    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + POD_FAILURE_TIME))
    local remote_cmds=(
        "kubectl get pods -o custom-columns=\"NAME:.metadata.name,NODE:.spec.nodeName\" | grep \"$POD_FAILURE_NAME\" | awk '{print \$2}'"
    )
    local host
    host=$(__exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}")
    local ip
    ip=$(hostname_to_ip "$host")
    now_ts=$(now)
    sleep_secs=$((wake_ts - now_ts))
    local remote_cmds=(
        "sleep $sleep_secs"
        "pids=\$(sudo crictl ps --name $POD_FAILURE_NAME -q | xargs sudo crictl inspect --output go-template --template '{{.info.pid}}')"
        "sudo kill -9 \$pids"
    )
    __exec_remote_commands "$USER" "$ip" "${remote_cmds[@]}"
}

attach_to_docker_container() {
    docker compose logs --follow --tail 1 loadgenerator director
}

log_cpu() {
    local interval_secs=10
    while true; do
        TS=$(date +%s)
        kubectl top pod |
            sed -n 's/  */,/gp' |
            sed -n 's/^\(.*\),\(.*\)m,.*$/\1,\2/gp' |
            sed -n "s/^/$TS,/gp" >>"$OUTPUT_DIR/cpu.csv"
        sleep "$interval_secs"
    done
}

main() {
    OUTPUT_DIR="$PWD/$EXPERIMENT_MODE-failure-experiment"
    backup_dir "$OUTPUT_DIR"
    log_info "Starting Robot Shop"
    start_robot_shop_local
    mkdir -p "$OUTPUT_DIR"
    save_config
    log_info "Starting LoadGenerator and saving initial schedule"
    local remote_cmds=(
        "kubectl get pods -o wide"
    )
    local initial_schedule
    initial_schedule=$(__exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}")
    printf "%s\n" "$initial_schedule" >"$OUTPUT_DIR/schedule.log"
    log_info "Saved initial_schedule"
    log_cpu &
    start_loadgenerator
    log_info "Started Loadgenerator"
    case "$EXPERIMENT_MODE" in
    "node") inject_node_failure "$(now)" & ;;
    "pod") inject_pod_failure "$(now)" & ;;
    "*") echo "INVALID EXPERIMENT MODE $EXPERIMENT_MODE" >&2 ;;
    esac
    attach_to_docker_container
    jobs -p | xargs kill
}

main "$@"
