#!/usr/bin/env bash
set -eou pipefail

# GENERAL CONFIGURATION
# SERVER_IP=$(kubectl get nodes | grep large-pool | awk '{print $1}')
EMAIL="mygcloud@email.com"
LOCAL_STORAGE_YAML="robot-local-storage.yml"
STANDARD_STORAGE_YAML="robot-standard-storage.yml"
EXPERIMENT_MODE="pod" # "node" or "pod" or "real"
EXPERIMENT_NAME="pod-failure-without-retry"
if [ "$EXPERIMENT_MODE" = "real" ]; then
    SERVER_IP=$(kubectl get nodes | grep default-pool | awk '{print $1}' | head -n 1)
else
    SERVER_IP=$(kubectl get nodes | grep large-pool | awk '{print $1}')
fi

GCLOUD_PROJECT="replacewithprojectid"
CLUSTER="my-cluster"
ZONE="us-central1-f"
SMALL_POOL="default-pool"
LARGE_POOL="large-pool"

# NODE FAILURE CONFIGURATION
select_node_failure_instance() {
    local instance
    instance=$(kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers | shuf -n 1)
    echo "$instance"
}
NODE_FAILURE_INSTANCE=$(select_node_failure_instance)
NODE_FAILURE_TIME=30

# POD FAILURE CONFIGURATION
POD_FAILURE_NAME="catalogue"
POD_FAILURE_TIME=60

# LOADGENERATOR CONFIGURATION
LUA_FILE="$PWD/workloads/cart-add.lua"
# LUA_FILE="$PWD/workloads/fullrobotshop-dynamicparameters.lua"
PROFILE="$PWD/load/constant_12rps_3min.csv"
# PROFILE = "$PWD/load/real-trace.csv"
TIMEOUT=20000
VIRTUAL_USERS=96
WARMUP_DURATION=120
WARMUP_RPS=3
WARMUP_PAUSE=22

__exec_remote_commands() {
    local user="$1"
    shift
    local ip="$1"
    shift
    local cmds=""
    while IFS= read -r cmd; do
        cmds+="$cmd; "
    done < <(printf "%s\n" "$@")
    gcloud compute ssh "$user"@"$ip" --command="bash" <<<"$cmds"
}

LOG_CPU=true
PIDS=()

kill_background_jobs() {
    LOG_CPU=false
    for pid in "${PIDS[@]}"; do
        kill "$pid" 2>/dev/null
    done
    wait "${PIDS[@]}" 2>/dev/null || true
    PIDS=()
}

cleanup() {
    echo "Caught Ctrl+C! Cleaning up..."
    # Kill all background jobs started by this script
    kill_background_jobs
    exit 1
}

trap cleanup SIGINT

hostname_to_ip() {
    kubectl get node "$1" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}'
}

now() {
    date +%s
}

setup_autoscaling() {
    find "$HOME/robot-shop/K8s" -type f -name "autoscaler*.yaml" -exec kubectl apply -f {} \;

    # Setup minimum and maximum node counts for 'small pool'
    gcloud container clusters update "$CLUSTER" \
        --enable-autoscaling \
        --min-nodes=1 \
        --max-nodes=5 \
        --node-pool="$SMALL_POOL" \
        --zone="$ZONE" \
        --quiet

    # Delete 'large pool'
    if gcloud container node-pools list --cluster="$CLUSTER" --zone="$ZONE" --format="value(name)" | grep -Fx "$LARGE_POOL"; then
        gcloud container node-pools delete "$LARGE_POOL" --cluster="$CLUSTER" --zone="$ZONE" --quiet
    fi

    # Scale 'small pool' to 2 nodes
    gcloud container clusters resize "$CLUSTER" \
        --node-pool="$SMALL_POOL" \
        --num-nodes=2 \
        --zone="$ZONE" \
        --quiet
}

cleanup_autoscaling() {
    find "$HOME/robot-shop/K8s" -type f -name "autoscaler*.yaml" -exec kubectl delete -f {} \;
    gcloud container clusters update "$CLUSTER" \
        --no-enable-autoscaling \
        --node-pool="$SMALL_POOL" \
        --zone="$ZONE" \
        --quiet
    gcloud container clusters resize "$CLUSTER" \
        --node-pool="$SMALL_POOL" \
        --num-nodes=1 \
        --zone="$ZONE" \
        --quiet
    gcloud container \
        --project "$GCLOUD_PROJECT" \
        node-pools create "$LARGE_POOL" \
        --cluster "$CLUSTER" \
        --zone "$ZONE" \
        --machine-type "e2-custom-8-12288" \
        --image-type "COS_CONTAINERD" \
        --disk-type "pd-balanced" \
        --disk-size "100" \
        --metadata disable-legacy-endpoints=true \
        --num-nodes "1" \
        --enable-autoupgrade \
        --enable-autorepair \
        --max-surge-upgrade 1 \
        --max-unavailable-upgrade 0 \
        --shielded-integrity-monitoring \
        --no-shielded-secure-boot \
        --node-locations "$ZONE"
}

log_info() {
    printf "[INFO]: %s\n" "$@" >&2
}

save_config() {
    local out="$OUTPUT_DIR/config.yml"
    kubectl get nodes -o yaml >"$OUTPUT_DIR/nodes.yaml"
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
            printf "failure_instance: %s\n" "$NODE_FAILURE_INSTANCE"
            printf "failure_time: %s\n" "$NODE_FAILURE_TIME"
        } >>"$out"
        ;;
    "pod")
        {
            printf "pod_failure_name: %s\n" "$POD_FAILURE_NAME"
            printf "failure_time: %s\n" "$POD_FAILURE_TIME"
        } >>"$out"
        ;;
    "real") ;;
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

start_robot_shop_remote() {
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

install_chaos_mesh() {
    helm repo add chaos-mesh https://charts.chaos-mesh.org
    kubectl create ns chaos-mesh --dry-run=client -o yaml | kubectl apply -f -
    if helm list -n chaos-mesh | grep "chaos-mesh"; then
        return
    fi
    helm install chaos-mesh chaos-mesh/chaos-mesh -n=chaos-mesh --set chaosDaemon.runtime=containerd --set chaosDaemon.socketPath=/run/containerd/containerd.sock --version 2.7.2
    kubectl apply -f role.yaml
    local cluster_role
    cluster_role=$(mktemp)
    sed "s/<my-email>/$EMAIL/g" clusterrole.yaml >"$cluster_role"
    kubectl apply -f "$cluster_role"
    rm "$cluster_role"
}

start_robot_shop_local() {
    if [ ! -d "$HOME/robot-shop" ]; then
        git clone https://github.com/yanniklubas/robot-shop.git "$HOME/robot-shop"
    fi

    local remote_cmds=(
        "mkdir -p /home/$USER/robot-local"
        "mkdir -p /home/$USER/robot-standard"
    )
    __exec_remote_commands "$USER" "$SERVER_IP" "${remote_cmds[@]}"

    local local_storage
    local_storage=$(mktemp)
    sed "s/REPLACE_HOSTNAME/$SERVER_IP/g" "$HOME/robot-shop/K8s/$LOCAL_STORAGE_YAML" >"$local_storage"
    sed -i "s/REPLACE_USER/$USER/g" "$local_storage"
    local standard_storage
    standard_storage=$(mktemp)
    sed "s/REPLACE_HOSTNAME/$SERVER_IP/g" "$HOME/robot-shop/K8s/$STANDARD_STORAGE_YAML" >"$standard_storage"
    sed -i "s/REPLACE_USER/$USER/g" "$standard_storage"

    if helm list | grep "robot-shop"; then
        helm uninstall robot-shop
        kubectl delete pod rabbitmq-server-0 --wait
        kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq --type json --patch='[ { "op": "remove", "path": "/metadata/finalizers" } ]'
        kubectl delete pvc --all
        kubectl delete pv --all
        kubectl wait --for=delete pod --all --timeout -1s
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
        cd load-generator/tools.descartes.dlim.httploadgenerator
        mvn clean package
        cd docker
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
            docker compose config \
            --output out.yml
        docker compose \
            --file out.yml \
            up \
            --force-recreate --wait --build
    )
}

inject_node_failure() {
    local start="$1"
    local sleep_secs
    local now_ts
    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + NODE_FAILURE_TIME))
    now_ts=$(now)
    sleep_secs=$((wake_ts - now_ts))
    kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: GCPChaos
metadata:
  name: node-stop-example
  namespace: chaos-mesh
spec:
  action: node-stop
  secretName: 'cloud-key-secret'
  project: '$GCLOUD_PROJECT'
  zone: '$ZONE'
  instance: '$NODE_FAILURE_INSTANCE'
  duration: '${sleep_secs}s'
EOF
}

inject_pod_failure() {
    local start="$1"
    local sleep_secs
    local now_ts
    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + POD_FAILURE_TIME))
    now_ts=$(now)
    sleep_secs=$((wake_ts - now_ts))
    sleep "$sleep_secs"
    kubectl apply -f - <<EOF
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill-$POD_FAILURE_NAME
  namespace: default
spec:
  action: pod-kill
  mode: one
  selector:
    namespaces:
      - default
    labelSelectors:
      'service': '$POD_FAILURE_NAME'
EOF
}

attach_to_docker_container() {
    (
        cd load-generator/tools.descartes.dlim.httploadgenerator/docker
        docker compose --file out.yml logs --follow --tail 1 director
        docker compose --file out.yml down
        rm out.yml
    )
}

log_cpu() {
    local interval_secs=10
    while [[ "$LOG_CPU" == "true" ]]; do
        TS=$(date +%s)
        kubectl top pod |
            sed -n 's/  */,/gp' |
            sed -n 's/^\(.*\),\(.*\)m,.*$/\1,\2/gp' |
            sed -n "s/^/$TS,/gp" >>"$OUTPUT_DIR/cpu.csv"
        sleep "$interval_secs"
    done
}

log_scheduling_events() {
    start_time=$(date -u +%s) && kubectl get events --all-namespaces --watch --field-selector involvedObject.kind=Pod,reason=Scheduled -o json | jq --unbuffered --argjson start_time "$start_time" '
select(.involvedObject.kind=="Pod" and .reason=="Scheduled") |
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/scheduling_events.json"
}

log_autoscaler_events() {
    start_time=$(date -u +%s) && kubectl get events -n kube-system --watch --field-selector involvedObject.name=cluster-autoscaler -o json | jq --unbuffered --argjson start_time "$start_time" '
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/autoscaling_events.json"
}

main() {
    local repeats="${1:-1}"
    OUTPUT_DIR="$PWD/$EXPERIMENT_NAME"
    backup_dir "$OUTPUT_DIR"
    for ((i = 0; i < repeats; i++)); do
        OUTPUT_DIR="$OUTPUT_DIR/$EXPERIMENT_MODE-failure-experiment-$i"
        mkdir -p "$OUTPUT_DIR"

        if [ "$EXPERIMENT_MODE" = "pod" ]; then
            install_chaos_mesh
        fi
        if [ "$EXPERIMENT_MODE" = "node" ]; then
            install_chaos_mesh
        fi
        if [ "$EXPERIMENT_MODE" = "real" ]; then
            setup_autoscaling
            log_autoscaler_events &
            PIDS+=($!)
        fi

        log_info "Starting Robot Shop"
        log_scheduling_events &
        PIDS+=($!)
        start_robot_shop_local
        save_config
        log_info "Starting LoadGenerator and saving initial schedule"
        kubectl get pods -o wide >"$OUTPUT_DIR/schedule.log"
        log_info "Saved initial_schedule"
        start_loadgenerator
        log_cpu &
        PIDS+=($!)
        log_info "Started Loadgenerator"
        case "$EXPERIMENT_MODE" in
        "node")
            inject_node_failure "$(now)" &
            ;;
        "pod")
            inject_pod_failure "$(now)" &
            ;;
        "real") ;;
        "*") echo "INVALID EXPERIMENT MODE $EXPERIMENT_MODE" >&2 ;;
        esac
        attach_to_docker_container
        if [ "$EXPERIMENT_MODE" = "pod" ]; then
            local pod
            pod=$(kubectl get pod | grep "$POD_FAILURE_NAME" | awk '{print $1}')
            kubectl get pod "$pod" -o json | jq -r '
  .status as $status |
  ($status.startTime | sub("\\..*";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $start |
  ($status.conditions[] | select(.type == "Ready") | .lastTransitionTime | sub("\\..*";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $ready |
  "ready_duration_secs: \($ready - $start)"
' >"$OUTPUT_DIR/ready_duration.yml"
            kubectl delete podchaos --all
        fi

        if [ "$EXPERIMENT_MODE" = "node" ]; then
            kubectl delete gcpchaos --all
        fi

        if [ "$EXPERIMENT_MODE" = "real" ]; then
            cleanup_autoscaling
        fi

        kill_background_jobs
        log_info "Finished experiment"
    done
}

main "$@"
