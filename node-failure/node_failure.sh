#!/usr/bin/env bash

# EXPERIMENT CONFIGURATION
WITH_CIRCUITBREAKER=false
NODE_FAILURE_TIME=120

# GCLOUD CONFIGURATION
CLUSTER="yannik-cluster"
ZONE="us-central1-f"
SMALL_POOL="default-pool"
LARGE_POOL="large-pool"

# LOADGENERATOR CONFIGURATION
LUA_FILE="$PWD/workloads/node-failure.lua"
PROFILE="$PWD/load/constant_36rps_15min.csv"
VIRTUAL_USERS=360
TIMEOUT=10000
WARMUP_DURATION=120
WARMUP_RPS=5
WARMUP_PAUSE=12

# GLOBAL VARIABLES
CLEANUP_DONE=false
APP_REPO="$PWD/robot-shop"
MANIFESTS_PATH="$PWD/manifests"
TEMPLATES_PATH="$MANIFESTS_PATH/robot-shop/templates"
LOADGENERATOR_PATH="$PWD/http-loadgenerator"
LOADGENERATOR_BUILD_PATH="$LOADGENERATOR_PATH/tools.descartes.dlim.httploadgenerator"
LOADGENERATOR_DOCKER_PATH="$LOADGENERATOR_BUILD_PATH/docker"
LOADGENERATOR_DOCKER_COMPOSE_FILE="$LOADGENERATOR_DOCKER_PATH/loadgenerator-node-failure.yml"
SCHEDULING_EVENTS_FILENAME="scheduling.json"
NODE_EVENTS_FILENAME="node_events.json"

if [[ "$WITH_CIRCUITBREAKER" == true ]]; then
    EXPERIMENT_NAME="node-failure-with-cb"
else
    EXPERIMENT_NAME="node-failure-without-cb"
fi
BASE_DIR="$PWD/$EXPERIMENT_NAME"

NODE_FAILURE_INSTANCE=""
select_node_failure_instance() {
    local matches count
    matches=$(kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers | grep "$LARGE_POOL")

    count=$(echo "$matches" | wc -l)

    if [[ "$count" -eq 1 ]]; then
        NODE_FAILURE_INSTANCE="$matches"
    else
        echo "Found $count nodes as failure instance"
        exit 1
    fi
}
select_node_failure_instance
# ++++++++++++++++++++++
# ++ HELPER FUNCTIONS ++
# ++++++++++++++++++++++
kill_jobs() {
    for pid in $(jobs -rp); do
        if kill -- "-$pid"; then
            echo "Successfully killed PGID $pid."
        else
            echo "Failed to kill PGID $pid."
        fi
    done
    wait 2>/dev/null || true
    echo "Successfully killed all background jobs"
}

backup_dir() {
    local path="$1"
    local counter=1

    if [[ -d "$path" ]]; then
        echo "Backing up directory: $path"
        local backup_path="$path-$counter"
        while [[ -d "$backup_path" ]]; do
            ((counter++))
            backup_path="$path-$counter"
        done

        echo "Moving $path to $backup_path..."
        if mv "$path" "$backup_path"; then
            echo "Successfully backed up $path to $backup_path!"
        else
            echo "Failed to back up directory $path to $backup_path!"
            return 1
        fi
    else
        echo "No directory found at $path. Nothing to back up."
    fi
}

now() {
    date "+%s"
}

enable_autoscaling() {
    # SMALL NODES
    local min_nodes=1
    local max_nodes=5
    gcloud container clusters update "$CLUSTER" \
        --enable-autoscaling \
        --min-nodes=$min_nodes \
        --max-nodes=$max_nodes \
        --node-pool="$SMALL_POOL" \
        --zone="$ZONE" \
        --quiet

    # LARGE NODES
    min_nodes=1
    max_nodes=5
    gcloud container clusters update "$CLUSTER" \
        --enable-autoscaling \
        --min-nodes=$min_nodes \
        --max-nodes=$max_nodes \
        --node-pool="$LARGE_POOL" \
        --zone="$ZONE" \
        --quiet
}

disable_autoscaling() {
    # SMALL NODES
    gcloud container clusters update "$CLUSTER" \
        --no-enable-autoscaling \
        --node-pool="$SMALL_POOL" \
        --zone="$ZONE" \
        --quiet

    # LARGE NODES
    gcloud container clusters update "$CLUSTER" \
        --no-enable-autoscaling \
        --node-pool="$LARGE_POOL" \
        --zone="$ZONE" \
        --quiet
}

reset_cluster() {
    # SMALL NODES
    gcloud container clusters resize "$CLUSTER" \
        --node-pool "$SMALL_POOL" \
        --num-nodes=1 \
        --zone="$ZONE" \
        --quiet
    # LARGE NODES
    gcloud container clusters resize "$CLUSTER" \
        --node-pool "$LARGE_POOL" \
        --num-nodes=1 \
        --zone="$ZONE" \
        --quiet
}

save_experiment_config() {
    local out_file="$1"

    local duration
    duration=$(wc -l "$PROFILE" | awk '{print $1}')

    echo "Saving experiment configuration to $out_file..."

    {
        printf "profile: %s\n" "$PROFILE"
        printf "duration_secs: %d\n" "$duration"
        printf "timeout: %s\n" "$TIMEOUT"
        printf "virtual_users: %s\n" "$VIRTUAL_USERS"
        printf "warmup_duration: %s\n" "$WARMUP_DURATION"
        printf "warmup_rps: %s\n" "$WARMUP_RPS"
        printf "warmup_pause: %s\n" "$WARMUP_PAUSE"
        printf "failure_instance: %s\n" "$NODE_FAILURE_INSTANCE"
        printf "failure_time: %s\n" "$NODE_FAILURE_TIME"
    } >"$out_file"

    echo "Experiment configuration saved to $out_file!"
}

log_scheduling_events() {
    local start_time
    start_time=$(date -u +%s)

    kubectl get events \
        -n default \
        --watch \
        --field-selector involvedObject.kind=Pod \
        -o json |
        jq --unbuffered --argjson start_time "$start_time" '
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/$SCHEDULING_EVENTS_FILENAME"
}

log_node_events() {
    local start_time
    start_time=$(date -u +%s)

    kubectl get events \
        --all-namespaces \
        --watch \
        --field-selector involvedObject.kind=Node \
        -o json |
        jq --unbuffered --argjson start_time "$start_time" '
select(.reason=="NodeReady" or .reason=="NodeNotReady") |
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/$NODE_EVENTS_FILENAME"
}
# ++++++++++++++++++
# ++ GLOBAL SETUP ++
# ++++++++++++++++++

# Enable job control option
set -m

cleanup() {
    if [ $CLEANUP_DONE ]; then
        return
    fi
    echo "Cleaning up..."

    kill_jobs

    CLEANUP_DONE=true
}

trap cleanup EXIT SIGINT SIGTERM

# ++++++++++++++++++++++
# ++ EXPERIMENT SETUP ++
# ++++++++++++++++++++++

setup_application() {
    echo "Starting robot shop setup..."

    if [[ ! -d "$APP_REPO" ]]; then
        echo "Cloning robot shop repository to $APP_REPO..."
        git clone https://github.com/yanniklubas/robot-shop.git "$APP_REPO" || exit 1
    fi

    (
        cd "$APP_REPO" || exit 1

        git checkout node-failure
    )

    mkdir -p "$MANIFESTS_PATH"

    echo "Generating helm manifests for robot shop..."

    helm template robot-shop "$APP_REPO/K8s/helm" \
        --output-dir "$MANIFESTS_PATH" \
        --values "$PWD/values.yaml"

    echo "Applying local storage class..."
    kubectl apply -f "$APP_REPO/K8s/local-storage-class.yml"

    echo "Adding RabbitMQ Operator helm repository..."
    helm repo add rabbitmq https://charts.bitnami.com/bitnami
}

start_application() {

    local infra_services=("mongodb" "mysql" "rabbitmq")
    local app_services=(
        "cart"
        "catalogue"
        "dispatch"
        "payment"
        "ratings"
        "shipping"
        "user"
        "web"
    )

    echo "Deploying robot shop..."

    # -- Helper functions --
    delete_services() {
        for service in "$@"; do
            echo "Deleting service: $service"
            if [[ "$WITH_CIRCUITBREAKER" == true &&
                ($service == "cart" || $service == "ratings") ]]; then
                kubectl delete \
                    -f "$TEMPLATES_PATH/$service-cb-deployment.yaml" \
                    --now \
                    --timeout 1s ||
                    true
            else
                kubectl delete \
                    -f "$TEMPLATES_PATH/$service-deployment.yaml" \
                    --now \
                    --timeout 1s ||
                    true
            fi
            kubectl delete -f "$TEMPLATES_PATH/$service-service.yaml" --now --timeout 1s || true
        done
    }

    wait_for_delete() {
        for service in "$@"; do
            echo "Waiting for service $service to terminate"
            kubectl wait --for=delete pod -l "service=$service" --timeout -1s || true
            echo "Service $service terminated"
        done
    }

    apply_services() {
        for service in "$@"; do
            echo "Applying service: $service"
            if [[ "$WITH_CIRCUITBREAKER" == true &&
                ($service == "cart" || $service == "ratings") ]]; then
                kubectl apply -f "$TEMPLATES_PATH/$service-cb-deployment.yaml"
            else
                kubectl apply -f "$TEMPLATES_PATH/$service-deployment.yaml"
            fi
            kubectl apply -f "$TEMPLATES_PATH/$service-service.yaml"
        done
    }

    wait_for_ready() {
        for service in "$@"; do
            echo "Waiting for service $service to become ready..."
            kubectl wait --for=condition=Ready pod -l "service=$service" --timeout -1s || true
            echo "Service $service is ready"
        done
    }

    if [[ -d "$MANIFESTS_PATH" ]]; then
        echo "Deleting existing robot shop deployment..."

        kubectl delete -f "$TEMPLATES_PATH/redis-statefulset.yaml" || true
        kubectl delete -f "$TEMPLATES_PATH/redis-service.yaml" || true

        delete_services "${infra_services[@]}"
        delete_services "${app_services[@]}"

        # RabbitMQ Operator
        kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq \
            --type json \
            --patch='[{"op": "remove", "path": "metadata/finalizers"}]' || true
        kubectl delete pod rabbitmq-server-0 --now || true

        echo "Waiting for all pods to terminate..."
        wait_for_delete "${infra_services[@]}"
        wait_for_delete "${app_services[@]}"
    fi

    echo "Cleaning up persistent volumes and persistent volume claims..."

    # Persistent Volume Claims
    for pvc in $(kubectl get pvc -n default -o jsonpatch='{.items[*].metadata.name}'); do
        kubectl patch pvc "$pvc" \
            -n default \
            -p '{"metadata": {"finalizers": []}}' \
            --type merge || true
    done
    kubectl delete pvc --all --grace-period=0 --force

    # Persistent Volumes
    for pv in $(kubectl get pv -n default -o jsonpatch='{.items[*].metadata.name}'); do
        kubectl patch pv "$pv" \
            -n default \
            -p '{"metadata": {"finalizers": []}}' \
            --type merge || true
    done
    kubectl delete pv --all --grace-period=0 --force

    # RabbitMQ Operator uninstall
    if helm list --namespace default | grep "^rabbitmq-operator" >/dev/null 2>&1; then
        helm uninstall rabbitmq-operator --wait
    fi

    echo "Applying service: redis"
    kubectl apply -f "$TEMPLATES_PATH/redis-statefulset.yaml"
    kubectl apply -f "$TEMPLATES_PATH/redis-service.yaml"

    apply_services "${infra_services[@]}"
    apply_services "${app_services[@]}"

    # RabbitMQ Operator install
    helm install rabbitmq-operator \
        rabbitmq/rabbitmq-cluster-operator \
        --version 3.6.6 \
        --values "$PWD/rabbitmq_values.yaml"

    wait_for_ready "${infra_services[@]}"
    wait_for_ready "${app_services[@]}"

    local replicas=2
    echo "Scaling web service to $replicas replicas"
    kubectl scale deployment -l service=web "--replicas=$replicas"
    wait_for_ready "web"

    echo "Robot shop is up and running!"
}

query_web_service_ip_and_port() {
    local max_tries=5
    local tmp
    tmp=$(mktemp)

    echo "Attempting to get web service IP and port (max tries: $max_tries)..." >&2
    for ((i = 0; i < "$max_tries"; i++)); do
        echo "Try #$i: fetching web service IP and port..." >&2
        if kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}:{.spec.ports[?(@.name=="http")].port}' >"$tmp"; then
            cat "$tmp"
            rm -f "$tmp"
            return 0
        fi

        truncate -s 0 "$tmp"
        sleep 1
    done

    echo "Failed to get web service IP and port after $max_tries attempts."
    rm -f "$tmp"
    return 1
}

setup_loadgenerator() {

    if [ ! -d "$LOADGENERATOR_PATH" ]; then
        echo "Cloning HTTP-Loadgenerator repository to $LOADGENERATOR_PATH..."
        git clone \
            https://github.com/yanniklubas/HTTP-Load-Generator.git \
            "$LOADGENERATOR_PATH" || exit 1
    fi

    (
        cd "$LOADGENERATOR_PATH" || exit 1

        git checkout node-failure-retry

        cd "$LOADGENERATOR_BUILD_PATH" || exit 1

        echo "Building HTTP loadgenerator with maven..."
        mvn clean package || exit 1
    )
}

start_loadgenerator() {
    (
        cd "$LOADGENERATOR_DOCKER_PATH" || exit 1

        local lua_file
        lua_file=$(mktemp)

        local ip_and_port
        ip_and_port=$(query_web_service_ip_and_port)

        local ip="${ip_and_port%:*}"
        local port="${ip_and_port#*:}"

        if [[ -z "$ip" || -z "$port" ]]; then
            echo "Invalid IP or port retrieved: $ip_and_port"
            exit 1
        fi

        # Replace placeholders in lua file
        sed "s/REPLACE_HOSTNAME/$ip/g" "$LUA_FILE" >"$lua_file"
        sed -i "s/REPLACE_PORT/$port/g" "$lua_file"

        echo "Generating docker compose configuration..."
        LUA_FILE="$lua_file" \
            OUTPUT_DIR="$OUTPUT_DIR" \
            PROFILE="$PROFILE" \
            VIRTUAL_USERS="$VIRTUAL_USERS" \
            TIMEOUT="$TIMEOUT" \
            WARMUP_DURATION="$WARMUP_DURATION" \
            WARMUP_RPS="$WARMUP_RPS" \
            WARMUP_PAUSE="$WARMUP_PAUSE" \
            docker compose config \
            --output "$LOADGENERATOR_DOCKER_COMPOSE_FILE"

        echo "Starting docker compose services for loadgenerator..."
        docker compose \
            --file "$LOADGENERATOR_DOCKER_COMPOSE_FILE" \
            up \
            --force-recreate \
            --wait \
            --build
        echo "Loadgenerator started successfully!"
    )
}

follow_logs() {
    docker compose \
        --file "$LOADGENERATOR_DOCKER_COMPOSE_FILE" \
        logs \
        --follow \
        --tail 1 \
        director
}

inject_node_failure() {
    local start_ts="$1"
    local sleep_secs now_ts wake_ts

    wake_ts=$((start_ts + WARMUP_DURATION + WARMUP_PAUSE + NODE_FAILURE_TIME))
    now_ts=$(now)

    sleep_secs=$((wake_ts - now_ts))
    echo "Sleeping for $sleep_secs seconds before injecting node failure..."
    sleep "$sleep_secs"
    echo "Injecting node failure on instance $NODE_FAILURE_INSTANCE"

    if gcloud compute ssh \
        "$USER@$NODE_FAILURE_INSTANCE" \
        --command="nohup sudo poweroff --force >/dev/null 2>&1 &"; then
        echo "Successfully injected node failure on $NODE_FAILURE_INSTANCE!"
    else
        echo "Failed to inject node failure on $NODE_FAILURE_INSTANCE!"
    fi
}

save_circuitbreaker_logs() {
    local pod

    # Cart service
    pod=$(kubectl get pod | grep "cart" | awk '{print $1}')
    kubectl logs "$pod" | grep "CircuitBreaker" >"$OUTPUT_DIR/cart.log" || true

    # Ratings service
    pod=$(kubectl get pod | grep "ratings" | awk '{print $1}')
    kubectl logs "$pod" | grep "CircuitBreaker:" >"$OUTPUT_DIR/ratings.log" || true
}

measure_node_latencies() {
    local prefix="$1"
    local namespace="kube-system"
    local label="app=netperf"
    local measurement_file="$OUTPUT_DIR/$prefix-rtt-measurements.json"
    local schedule_file="$OUTPUT_DIR/$prefix-rtt-schedule.json"
    local tmp_file
    local duration=5 # seconds for each netperf test

    echo "Starting netperf daemon sets for node RTT measurements"
    kubectl apply -f netperf.yaml

    local max_attempts=30
    local attempt
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if kubectl get pods -n "$namespace" -l "$label" | grep -q netperf; then
            break
        fi
        echo "Waiting for netperf pods to be created ($attempt/$max_attempts)..."
        sleep 1
    done
    kubectl wait \
        -n "$namespace" \
        --for=condition=Ready \
        pod \
        -l "$label" \
        --timeout -1s
    echo "Netperf daemonsets are ready!"

    kubectl get pods -n "$namespace" -l "$label" \
        -o=jsonpath='{range .items[*]}{"{\"podName\":\""}{.metadata.name}{"\",\"podIP\":\""}{.status.podIP}{"\",\"nodeName\":\""}{.spec.nodeName}{"\",\"nodeIP\":\""}{.status.hostIP}{"\"}\n"}{end}' >"$schedule_file"

    mapfile -t PODS < <(kubectl get pods -n "$namespace" -l "$label" -o jsonpath="{range .items[*]}{.metadata.name} {.status.podIP}{'\n'}{end}")
    if [[ ${#PODS[@]} -lt 2 ]]; then
        echo "Need at least two pods for node RTT measurements."
        exit 1
    fi
    tmp_file=$(mktemp)
    echo "[" >"$tmp_file"
    for SRC in "${PODS[@]}"; do
        SRC_POD=$(awk '{print $1}' <<<"$SRC")
        SRC_IP=$(awk '{print $2}' <<<"$SRC")
        for DST in "${PODS[@]}"; do
            DST_POD=$(awk '{print $1}' <<<"$DST")
            DST_IP=$(awk '{print $2}' <<<"$DST")
            if [[ "$SRC_POD" == "$DST_POD" ]]; then
                continue
            fi

            echo "$SRC_IP ($SRC_POD) → $DST_IP ($DST_POD)..."

            local result

            if ! result=$(kubectl exec -n "$namespace" "$SRC_POD" -c netperf -- \
                netperf -H "$DST_IP" -l "$duration" -t TCP_RR -- -o min_latency,max_latency,mean_latency,stddev_latency,p50_latency,p90_latency,p99_latency 2>&1); then
                echo "Failed to run netperf from $SRC_POD to $DST_POD"
                continue
            fi

            IFS=',' read -r -a LATENCIES <<<"${result##*$'\n'}"
            if [[ ${#LATENCIES[@]} -ne 7 ]]; then
                echo "Unexpected netperf output from $SRC_POD to $DST_POD: $result"
                continue
            fi

            cat <<EOF >>"$tmp_file"
  {
    "source_pod": "$SRC_POD",
    "source_ip": "$SRC_IP",
    "target_pod": "$DST_POD",
    "target_ip": "$DST_IP",
    "min_latency_ms": ${LATENCIES[0]},
    "max_latency_ms": ${LATENCIES[1]},
    "mean_latency_ms": ${LATENCIES[2]},
    "stddev_latency_ms": ${LATENCIES[3]},
    "p50_latency_ms": ${LATENCIES[4]},
    "p90_latency_ms": ${LATENCIES[5]},
    "p99_latency_ms": ${LATENCIES[6]},
  },
EOF
        done
    done

    # Remove trailing comma from last JSON object
    sed -i '$ s/},/}/' "$tmp_file"
    echo "]" >>"$tmp_file"
    mv "$tmp_file" "$measurement_file"

    echo "Cleaning up netperf daemonsets..."
    kubectl delete -f netperf.yaml
    kubectl wait -n "$namespace" --for=delete pod -l "$label" --timeout -1s

    echo "Node latencies results written to $measurement_file"
}

save_container_stats() {
    local start="$1"
    local end="$2"

    echo "Fetching Creo Monitor IP address..."
    local ip
    ip=$(kubectl get service creo-monitor-svc -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

    if [[ -z "$ip" ]]; then
        echo "Failed to retrieve Creo Monitor IP address!"
        exit 1
    fi

    echo "Queried Creo Monitor IP address: $ip"

    echo "Downloading container stats from $start to $end..."
    local page=1
    local page_size=10000
    local has_next=true
    while [[ "$has_next" = true ]]; do
        local output_file="$OUTPUT_DIR/creo_cpu_page_$page.json"
        if curl -sS "http://$ip/export?from=$start&to=$end&page=$page&page_size=$page_size" -o "$output_file"; then
            echo "Container stats saved to $output_file"

            has_next=$(jq -r '.hasNextPage' "$output_file" 2>/dev/null)
            if [ $? -ne 0 ] || [ -z "$has_next" ] || [ "$has_next" = "null" ]; then
                echo "Failed to parse hasNextPage from response"
                exit 1
            fi
            echo "Page $page hasNextPage: $has_next"
            page=$((page + 1))
        else
            echo "Failed to download container stats from Creo Monitor."
            exit 1
        fi
    done
}

main() {
    local repeats="${1:-1}"

    backup_dir "$BASE_DIR"

    setup_application
    setup_loadgenerator

    local i
    for ((i = 0; i < repeats; i++)); do
        OUTPUT_DIR="$BASE_DIR/node-failure-experiment-$i"
        mkdir -p "$OUTPUT_DIR"

        echo "Starting experiment iteration $i..."
        enable_autoscaling
        select_node_failure_instance

        measure_node_latencies "start"

        log_scheduling_events &
        log_node_events &

        save_experiment_config "$OUTPUT_DIR/config.yml"

        start_application

        start_loadgenerator

        # Failure injection
        local start_ts
        start_ts=$(now)
        inject_node_failure "$start_ts" &

        follow_logs

        # Container stats
        local end_ts
        end_ts=$(now)
        save_container_stats "$start_ts" "$end_ts"

        if [[ "$WITH_CIRCUITBREAKER" == true ]]; then
            save_circuitbreaker_logs
        fi

        kill_jobs

        measure_node_latencies "end"

        reset_cluster

        echo "Experiment iteration $i finished"
    done

    disable_autoscaling

    rm -r "$MANIFESTS_PATH"
    echo "All experiment iterations complete!"
}

main "$@"
