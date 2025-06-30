#!/usr/bin/env bash
set -eou pipefail

# GENERAL CONFIGURATION
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

PIDS=()
__exec_remote_commands() {
    local user="$1"
    shift
    local ip="$1"
    shift

    log_debug "Executing remote commands on $user@$ip..."
    local cmds=""
    # while IFS= read -r cmd; do
    #     cmds+="$cmd; "
    # done < <(printf "%s\n" "$@")
    for cmd in "$@"; do
        cmds+="$cmd; "
    done

    log_debug "Remote command string: $cmds"

    gcloud compute ssh "$user@$ip" --command="$cmds" || {
        log_error "Remote commands execution failed on $user@$ip"
        return 1
    }
    log_debug "Remote commands executed successfully on $user@$ip"
}

kill_background_jobs() {
    if [ ${#PIDS[@]} -eq 0 ]; then
        log_info "No background jobs to kill."
        return
    fi
    for pid in "${PIDS[@]}"; do
        if log_command "kill \"$pid\""; then
            log_success "Successfully killed PID $pid."
        else
            log_error "Failed to kill PID $pid (might have already exited)."
        fi
    done
    log_command "wait ${PIDS[*]} || true"
    PIDS=()

    log_success "Killed all background jobs"
}

save_container_stats() {
    local start="$1"
    local end="$2"

    log_debug "Fetching Creo Monitor IP address..."
    local ip
    ip=$(kubectl get service creo-monitor-svc -n monitoring -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
    if [[ -z "$ip" ]]; then
        log_error "Failed to retrieve Creo Monitor IP."
        return 1
    fi
    log_debug "Queried Creo Monitor IP: $ip"

    log_info "Downloading container stats from $start to $end..."
    if log_command "curl -sS 'http://$ip/export?from=$start&to=$end' -o '$OUTPUT_DIR/creo_cpu.json'"; then
        log_success "Container stats saved to $OUTPUT_DIR/creo_cpu.json"
    else
        log_error "Failed to download container stats from Creo Monitor."
        return 1
    fi
}

get_pod_and_container_ids() {
    log_info "Fetching pod names, pod UIDs, and container IDs..."
    local output

    if output=$(kubectl get pods -o custom-columns=Name:.metadata.name,PodID:.metadata.uid,ContainerID:.status.containerStatuses[*].containerID); then
        echo "$output" | sed 's/containerd:\/\///g'
    else
        log_error "Failed to retrieve pod and container IDs."
        return 1
    fi

    log_success "Fetched pod names, pod UIDs, and container IDs..."
}

cleanup() {
    log_info "Caught Ctrl+C! Cleaning up..."
    kill_background_jobs
    if [[ "$EXPERIMENT_MODE" == "real" ]]; then
        log_info "Running autoscaling cleanup..."
        cleanup_autoscaling
    fi

    log_success "Cleanup done"
    exit 1
}

trap cleanup SIGINT

now() {
    date "+%s"
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

LOG_LEVEL="${LOG_LEVEL:-INFO}"
LOG_TIMESTAMP=true

# Color support
if [ -t 2 ]; then
    COLOR_INFO="\033[1;34m"
    COLOR_WARN="\033[1;33m"
    COLOR_ERROR="\033[1;31m"
    COLOR_SUCCESS="\033[1;32m"
    COLOR_DEBUG="\033[0;36m"
    COLOR_RESET="\033[0m"
else
    COLOR_INFO=""
    COLOR_WARN=""
    COLOR_ERROR=""
    COLOR_SUCCESS=""
    COLOR_DEBUG=""
    COLOR_RESET=""
fi

# Internal: timestamp helper
_log_ts() {
    [ "$LOG_TIMESTAMP" = true ] && date +"%Y-%m-%d %H:%M:%S" || echo ""
}

# Internal: log printer
_log() {
    local level="$1"
    local color="$2"
    shift 2
    local ts
    ts=$(_log_ts)
    printf "%b[%s] %s%s: %s%b\n" \
        "$color" \
        "${ts}" \
        "$level" \
        "$([ -n "$ts" ] && echo "")" \
        "$*" \
        "$COLOR_RESET" >&2
}

log_info() { [[ "$LOG_LEVEL" =~ ^(INFO|DEBUG)$ ]] && _log "INFO" "$COLOR_INFO" "$@"; }
log_warn() { [[ "$LOG_LEVEL" =~ ^(INFO|WARN|DEBUG)$ ]] && _log "WARN" "$COLOR_WARN" "$@"; }
log_error() { _log "ERROR" "$COLOR_ERROR" "$@"; }
log_success() { [[ "$LOG_LEVEL" =~ ^(INFO|DEBUG)$ ]] && _log "SUCCESS" "$COLOR_SUCCESS" "$@"; }
log_debug() { [[ "$LOG_LEVEL" == "DEBUG" ]] && _log "DEBUG" "$COLOR_DEBUG" "$@"; }
log_command() {
    # Detect if any shell metacharacters exist
    local cmd="$*"
    log_debug "Running: $*"
    bash -c "$cmd" >/dev/null 2>&1
}

save_config() {
    local out="$OUTPUT_DIR/config.yml"

    log_info "Saving Kubernetes nodes info to '$OUTPUT_DIR/nodes.yaml'..."
    if log_command "kubectl get nodes -o yaml >\"$OUTPUT_DIR/nodes.yaml\""; then
        log_success "Nodes info saved."
    else
        log_error "failed to get nodes info."
        return 1
    fi

    log_info "Writing experiment configuration to '$out'..."
    {
        printf "profile: %s\n" "$PROFILE"
        printf "timeout: %s\n" "$TIMEOUT"
        printf "virtual_users: %s\n" "$VIRTUAL_USERS"
        printf "warmup_duration: %s\n" "$WARMUP_DURATION"
        printf "warmup_rps: %s\n" "$WARMUP_RPS"
        printf "warmup_pause: %s\n" "$WARMUP_PAUSE"
        printf "server: %s\n" "$SERVER_IP"
    } >"$out"
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
    "real")
        log_debug "Experiment mode is 'real'; no additional config to save."
        ;;
    *)
        log_error "INVALID EXPERIMENT MODE $EXPERIMENT_MODE"
        return 1
        ;;
    esac

    log_success "Configuration saved to '$out'."
}

backup_dir() {
    local dir="$1"
    local counter=1

    if [[ -d "$dir" ]]; then
        log_info "Backing up directory: $dir"
        local backup="$dir-$counter"
        while [[ -d "$backup" ]]; do
            ((counter++))
            backup="$dir-$counter"
        done
        log_debug "Moving '$dir' to '$backup'"
        if log_command "mv \"$dir\" \"$backup\""; then
            log_success "Directory '$dir' backed up to '$backup'"
        else
            log_error "Failed to back up directory '$dir'"
            return 1
        fi
    else
        log_debug "No directory found at '$dir'; nothing to back up."
    fi
}

install_chaos_mesh() {
    local namespace="chaos-mesh"

    if [[ -z "$EMAIL" ]]; then
        log_error "Failed to install Chaos Mesh. EMAIL is not set."
        return 1
    fi

    # Skip installation if already installed
    log_info "Checking if Chaos Mesh is already installed..."
    if helm list --namespace "$namespace" | grep "^chaos-mesh" >/dev/null 2>&1; then
        log_info "Chaos Mesh is already installed. Skipping installation."
        return
    fi
    # Add the Chaos Mesh Helm repo and create the namespace if needed
    log_info "Adding Chaos Mesh Helm repo..."
    log_command "helm repo add chaos-mesh https://charts.chaos-mesh.org"
    log_info "Creating namespace '${namespace}' if it doesn't exist..."
    log_command "kubectl create namespace \"$namespace\" --dry-run=client -o yaml | kubectl apply -f -"

    log_info "Installing Chaos Mesh into namespace '${namespace}'..."
    log_command "helm install chaos-mesh chaos-mesh/chaos-mesh \
        --namespace \"$namespace\" \
        --set chaosDaemon.runtime=containerd \
        --set chaosDaemon.socketPath=/run/containerd/containerd.sock \
        --version 2.7.2"

    # Apply RBAC roles
    log_command "kubectl apply -f role.yaml"

    render_email_role() {
        local input="clusterrole.yaml"
        local output
        output=$(mktemp)
        sed "s/<my-email>/$EMAIL/g" "$input" >"$output"
        echo "$output"
    }
    local rendered_role
    rendered_role=$(render_email_role)
    log_command "kubectl apply -f \"$rendered_role\""
    rm "$rendered_role"
    log_info "Chaos Mesh installation completed."
}

setup_storage() {
    local node="$1"

    log_info "Setting up storage directories on node '$node'..."
    local remote_cmds=(
        "mkdir -p /home/$USER/robot-local"
        "mkdir -p /home/$USER/robot-standard"
    )
    __exec_remote_commands "$USER" "$node" "${remote_cmds[@]}"

    render_yaml() {
        local template_path="$1"
        local output
        output=$(mktemp)

        if [[ ! -f "$template_path" ]]; then
            log_error "Template not found: $template_path"
            exit 1
        fi

        log_command "sed -e \"s/REPLACE_HOSTNAME/$node/g\" \
            -e \"s/REPLACE_USER/$USER/g\" \
            -e \"s/REPLACE_NODE/$node/g\" \
            \"$template_path\" >\"$output\""

        echo "$output"
    }

    local local_template="$HOME/robot-shop/K8s/$LOCAL_STORAGE_YAML"
    local standard_template="$HOME/robot-shop/K8s/$STANDARD_STORAGE_YAML"

    log_debug "Rendering local storage YAML for node '$node'..."
    local local_yaml
    local_yaml=$(render_yaml "$local_template")

    log_debug "Rendering standard storage YAML for node '$node'..."
    local standard_yaml
    standard_yaml=$(render_yaml "$standard_template")

    log_info "Applying storage manifests for node '$node'..."
    if log_command "kubectl apply -f \"$local_yaml\" -f \"$standard_yaml\""; then
        log_success "Storage setup applied for node '$node'."
    else
        log_error "Failed to apply storage manifests for node '$node'."
    fi
    rm -f "$local_yaml" "$standard_yaml"
}

start_robot_shop() {
    local repo_dir="$HOME/robot-shop"
    local yamls_dir="$HOME/robot-yamls"
    local prefix="$yamls_dir/robot-shop/templates"

    local infra_services=("mongodb" "mysql" "rabbitmq")
    local app_services=("cart" "catalogue" "dispatch" "payment" "ratings" "shipping" "user" "web")

    log_info "Starting Robot Shop setup..."

    if [[ ! -d "$repo_dir" ]]; then
        log_info "Cloning Robot Shop repository..."
        log_command "git clone https://github.com/yanniklubas/robot-shop.git \"$repo_dir\""
    else
        log_debug "Repository already exists at $repo_dir"
    fi

    delete_services() {
        for service in "$@"; do
            log_debug "Deleting service: $service"
            log_command "kubectl delete -f \"$prefix/$service-deployment.yaml\" --now --timeout 1s || true"
            log_command "kubectl delete -f \"$prefix/$service-service.yaml\" --now --timeout 1s || true"
        done
    }

    wait_for_deleted_services() {
        for service in "$@"; do
            log_debug "Waiting for service '$service' to have terminated..."
            log_command "kubectl wait --for=delete pod -l \"service=$service\" --timeout -1s" || true
            log_success "Service '$service' terminated"
        done
    }

    apply_services() {
        for service in "$@"; do
            log_info "Applying service: $service"
            log_command "kubectl apply -f \"$prefix/$service-deployment.yaml\""
            log_command "kubectl apply -f \"$prefix/$service-service.yaml\""
        done
    }

    wait_for_services_ready() {
        for service in "$@"; do
            log_debug "Waiting for service '$service' to be ready..."
            log_command "kubectl wait --for=condition=Ready pod -l \"service=$service\" --timeout -1s" || true
            log_success "Service '$service' is ready"
        done
    }

    if [[ -d "$yamls_dir" ]]; then
        log_info "Deleting existing Robot Shop Kubernetes resources..."

        log_command "kubectl delete -f \"$prefix/redis-statefulset.yaml\" || true"
        log_command "kubectl delete -f \"$prefix/redis-service.yaml\" || true"

        delete_services "${infra_services[@]}"
        delete_services "${app_services[@]}"

        log_command "kubectl delete pod rabbitmq-server-0 --now || true"
        log_command "kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq --type json \
            --patch='[ { \"op\": \"remove\", \"path\": \"/metadata/finalizers\" } ]' || true"

        log_info "Waiting for all pods to terminate..."
        wait_for_deleted_services "${app_services[@]}"
        wait_for_deleted_services "${infra_services[@]}"
    fi

    log_info "Generating Helm manifests for Robot Shop..."
    mkdir -p "$yamls_dir"
    log_command "helm template robot-shop \"$repo_dir/K8s/helm\" --output-dir \"$yamls_dir\""

    log_info "Cleaning up persistent volumes..."
    log_command "kubectl delete pvc --all"
    log_command "kubectl delete pv --all"

    log_info "Applying local storage class..."
    log_command "kubectl apply -f \"$repo_dir/K8s/local-storage-class.yml\""

    export -f __exec_remote_commands
    export -f setup_storage
    export -f log_info
    export COLOR_INFO
    export -f log_debug
    export COLOR_DEBUG
    export -f log_error
    export COLOR_ERROR
    export -f log_success
    export COLOR_SUCCESS
    export COLOR_RESET
    export LOG_TIMESTAMP
    export LOG_LEVEL
    export -f log_command
    export -f _log
    export -f _log_ts

    log_info "Setting up storage on all nodes..."
    kubectl get nodes -o custom-columns=NAME:.metadata.name --no-headers |
        xargs -I {} bash -c 'LOCAL_STORAGE_YAML='"$LOCAL_STORAGE_YAML"' STANDARD_STORAGE_YAML='"$STANDARD_STORAGE_YAML"' setup_storage "$@"' _ {}

    log_info "Checking if RabbitMQOperator is already installed..."
    if helm list --namespace default | grep "^rabbitmq-operator"; then
        log_info "RabbitMQOperator is already installed. Skipping installation."
    else
        log_info "Did not find a RabbitMQOperator installation."
        log_info "Adding RabbitMQOperator Helm repo..."
        log_command helm repo add rabbitmq https://charts.bitnami.com/bitnami
        log_info "Installing RabbitMQOperator..."
        log_command helm install rabbitmq-operator rabbitmq/rabbitmq-cluster-operator --version 3.6.6
    fi

    log_info "Deploying Redis..."
    log_command "kubectl apply -f \"$prefix/redis-statefulset.yaml\"" || true
    log_command "kubectl apply -f \"$prefix/redis-service.yaml\"" || true

    log_info "Deploying infrastructure services..."
    apply_services "${infra_services[@]}"

    log_info "Deploying application services..."
    apply_services "${app_services[@]}"

    log_info "Waiting for all pods to become ready..."
    wait_for_services_ready "${app_services[@]}"
    wait_for_services_ready "${infra_services[@]}"

    log_success "Robot Shop is up and running!"
}

measure_node_latencies() {
    local prefix="$1"
    local namespace="kube-system"
    local label="app=netperf"
    local output_file="$OUTPUT_DIR/$prefix-rtt-measurements.json"
    local log_file="$OUTPUT_DIR/$prefix-rtt-schedule.json"
    local tmp_file
    local duration=5 # seconds for each netperf test

    log_info "Starting netperf daemon sets for node RTT measurements"
    log_command kubectl apply -f netperf.yaml
    for attempt in {1..30}; do
        if log_command "kubectl get pods -n \"$namespace\" -l \"$label\" | grep -q netperf"; then
            break
        fi
        log_debug "Waiting for netperf pods to be created ($attempt/30)..."
        sleep 1
    done
    log_command kubectl wait -n "$namespace" --for=condition=Ready pod -l "$label" --timeout -1s
    log_info "Netperf daemonsets are ready"

    log_command kubectl get pods -n "$namespace" -l "$label" -o=jsonpath=''\''{range .items[*]}{"{\"podName\":\""}{.metadata.name}{"\",\"podIP\":\""}{.status.podIP}{"\",\"nodeName\":\""}{.spec.nodeName}{"\",\"nodeIP\":\""}{.status.hostIP}{"\"}\n"}{end}'\''' ">\"$log_file\""

    mapfile -t PODS < <(kubectl get pods -n "$namespace" -l "$label" -o jsonpath="{range .items[*]}{.metadata.name} {.status.podIP}{'\n'}{end}")

    if [[ ${#PODS[@]} -lt 2 ]]; then
        log_error "Need at least two pods for node RTT measurements."
        exit 1
    fi

    tmp_file=$(mktemp)
    echo "[" >"$tmp_file"

    for SRC in "${PODS[@]}"; do
        log_debug "SRC=$SRC"
        SRC_POD=$(awk '{print $1}' <<<"$SRC")
        SRC_IP=$(awk '{print $2}' <<<"$SRC")
        log_debug "SRC_POD=$SRC_POD"
        log_debug "SRC_IP=$SRC_IP"

        for DST in "${PODS[@]}"; do
            log_debug "DST=$DST"
            DST_POD=$(awk '{print $1}' <<<"$DST")
            DST_IP=$(awk '{print $2}' <<<"$DST")
            log_debug "DST_POD=$DST_POD"
            log_debug "DST_IP=$DST_IP"

            if [[ "$SRC_POD" == "$DST_POD" ]]; then
                continue
            fi

            log_info "$SRC_IP ($SRC_POD) → $DST_IP ($DST_POD)..."

            local result
            if ! result=$(kubectl exec -n "$namespace" "$SRC_POD" -c netperf -- \
                netperf -H "$DST_IP" -l "$duration" -t TCP_RR -- -o min_latency,max_latency,mean_latency,stddev_latency,p50_latency,p90_latency,p99_latency 2>&1); then
                log_error "Failed to run netperf from $SRC_POD to $DST_POD"
                continue
            fi

            IFS=',' read -r -a LATENCIES <<<"${result##*$'\n'}"

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
    log_command sed -i "'\$ s/},/}/'" "$tmp_file"
    echo "]" >>"$tmp_file"
    log_command mv "$tmp_file" "$output_file"

    log_info "Cleaning up netperf daemonsets..."
    log_command kubectl delete -f netperf.yaml
    log_command kubectl wait -n "$namespace" --for=delete pod -l "$label" --timeout -1s

    log_success "Node latencies results written to '$output_file'"
}

get_web_ip_and_port() {
    local max_tries=5
    local stdout
    stdout=$(mktemp)

    log_info "Attempting to get web service IP and port (max tries: $max_tries)..."
    for ((i = 0; i < "$max_tries"; i++)); do
        log_debug "Try #$i: fetching web service IP and port..."
        if kubectl get service web -o jsonpath='{.status.loadBalancer.ingress[0].ip}:{.spec.ports[?(@.name=="http")].port}' >"$stdout"; then
            local result
            result=$(<"$stdout")
            if [[ -n "$result" ]]; then
                log_info "Successfully retrieved web IP and port: $result"
                echo "$result"
                rm -f "$stdout"
                return 0
            else
                log_warn "Received empty IP and port on try #$i"
            fi
        else
            log_warn "Failed to fetch IP and port on try #$i"
        fi
        sleep 1
        truncate -s 0 "$stdout"
    done

    log_error "Failed to get web service IP and port after $max_tries attempts."
    rm -f "$stdout"
    return 1
}

start_loadgenerator() {
    log_info "Starting load_generator"

    if [ ! -d "load-generator" ]; then
        log_info "Cloning HTTP-Load-Generator repository..."
        if ! log_command git clone https://github.com/yanniklubas/HTTP-Load-Generator.git "load-generator"; then
            log_error "Failed to clone load-generator repository."
            return 1
        fi
    else
        log_debug "Load  generator directory already exists."
    fi
    (
        cd load-generator/tools.descartes.dlim.httploadgenerator || {
            log_error "Failed to enter load-generator build directory."
            exit 1
        }
        log_info "Building load generator with Maven..."
        if ! log_command mvn clean package; then
            log_error "Maven build failed."
            exit 1
        fi

        cd docker || {
            log_error "Failed to enter docker directory."
            exit 1
        }

        local lua_file
        lua_file=$(mktemp) || {
            log_error "Failed to create temporary lua file."
            exit 1
        }

        local ip_and_port
        ip_and_port=$(get_web_ip_and_port) || {
            log_error "Failed to retrieve web IP and port."
            exit 1
        }

        local ip=${ip_and_port%:*}
        local port=${ip_and_port#*:}

        if [[ -z "$ip" || -z "$port" ]]; then
            log_error "Invalid IP or port retrieved: $ip_and_port"
            exit 1
        fi

        log_debug "Replacing placeholders in LUA script with IP: $ip and port: $port"
        sed "s/REPLACE_HOSTNAME/$ip/g" "$LUA_FILE" >"$lua_file"
        sed -i "s/REPLACE_PORT/$port/g" "$lua_file"

        log_info "Generating Docker Compose configuration..."
        if ! log_command LUA_FILE="$lua_file" \
            OUTPUT_DIR="$OUTPUT_DIR" \
            PROFILE="$PROFILE" \
            VIRTUAL_USERS="$VIRTUAL_USERS" \
            TIMEOUT="$TIMEOUT" \
            WARMUP_DURATION="$WARMUP_DURATION" \
            WARMUP_RPS="$WARMUP_RPS" \
            WARMUP_PAUSE="$WARMUP_PAUSE" \
            docker compose config \
            --output out.yml; then
            log_error "Docker Compose config generation failed."
            exit 1
        fi

        log_info "Starting Docker Compose services for load generator..."
        if ! log_command docker compose --file out.yml up --force-recreate --wait --build; then
            log_error "Failed to start load generator docker compose services."
            exit 1
        fi

        log_success "Load generator stated successfully."
    )
}

inject_node_failure() {
    local start="$1"
    local sleep_secs
    local now_ts

    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + NODE_FAILURE_TIME))
    now_ts=$(now)

    sleep_secs=$((wake_ts - now_ts))
    if ((sleep_secs > 0)); then
        log_info "Sleeping for $sleep_secs seconds before injecting node failure..."
        sleep "$sleep_secs"
    else
        log_warn "Scheduled wake time already passed by $((-sleep_secs)) seconds. Injecting failure immediately."
    fi

    log_info "Injecting node failure on instance '$NODE_FAILURE_INSTANCE'..."
    if log_command gcloud compute ssh "$USER@$NODE_FAILURE_INSTANCE" --command="sudo poweroff --force"; then
        log_success "Node failure injected successfully on '$NODE_FAILURE_INSTANCE'."
    else
        log_error "Failed to inject node failure on '$NODE_FAILURE_INSTANCE'."
    fi
}

inject_pod_failure() {
    local start="$1"
    local sleep_secs
    local now_ts

    wake_ts=$((start + WARMUP_DURATION + WARMUP_PAUSE + POD_FAILURE_TIME))
    now_ts=$(now)

    sleep_secs=$((wake_ts - now_ts))
    if ((sleep_secs > 0)); then
        log_info "Sleeping for $sleep_secs seconds before injecting pod failure..."
        sleep "$sleep_secs"
    else
        log_warn "Scheduled wake time already passed by $((-sleep_secs)) seconds. Injecting failure immediately."
    fi

    log_info "Injecting pod failure on pods labeled 'service=$POD_FAILURE_NAME' in namespace 'default'..."
    log_command kubectl apply -f - <<EOF
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
    local status=$?
    if [[ $status -eq 0 ]]; then
        log_success "Pod failure injected successfully."
    else
        log_error "Failed to inject pod failure."
    fi
}

attach_to_docker_container() {
    local docker_dir="load-generator/tools.descartes.dlim.httploadgenerator/docker"
    local compose_file="out.yml"

    log_info "Attaching to docker container logs (service: director)..."
    (
        cd "$docker_dir" || {
            log_error "Failed to cd into $docker_dir"
            return 1
        }
        docker compose --file out.yml logs --follow --tail 1 director
        log_info "Stopping and removing docker containers..."
        if log_command docker compose --file "$compose_file" down; then
            log_success "Docker containers stopped and removed."
        else
            log_error "Failed to stop/remove docker containers."
        fi

        if [[ -f "$compose_file" ]]; then
            rm -f "$compose_file"
            log_info "Removed $compose_file"
        else
            log_warn "$compose_file does not exist to remove."
        fi
    )
}

log_scheduling_events() {
    log_info "Starting to log scheduling events to scheduling_events.json..."
    local start_time
    start_time=$(date -u +%s) || {
        log_error "Failed to get current timestamp"
        return 1
    }
    kubectl get events --all-namespaces --watch --field-selector involvedObject.kind=Pod -o json | jq --unbuffered --argjson start_time "$start_time" '
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/scheduling_events.json"
}

log_autoscaler_events() {
    start_time=$(date -u +%s) && kubectl get events --all-namespaces --watch --field-selector involvedObject.name=cluster-autoscaler -o json | jq --unbuffered --argjson start_time "$start_time" '
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/autoscaling_events.json"
}

log_node_events() {
    log_info "Starting to log node events to node_events.json..."
    local start_time
    start_time=$(date -u +%s) || {
        log_error "Failed to get current timestamp"
        return 1
    }
    kubectl get events --all-namespaces --watch --field-selector involvedObject.kind=Node -o json | jq --unbuffered --argjson start_time "$start_time" '
select(.reason=="NodeReady" or .reason=="NodeNotReady") |
select(.lastTimestamp != null or .eventTime != null) |
.timestamp = (.lastTimestamp // .eventTime) |
.clean_timestamp = (.timestamp | sub("\\.[0-9]+Z$"; "Z")) |
select((.clean_timestamp | fromdateiso8601) > $start_time) |
{namespace: .metadata.namespace, pod: .involvedObject.name, reason: .reason, message: .message, time: .timestamp}
' >"$OUTPUT_DIR/node_events.json"

}

main() {
    local repeats="${1:-1}"
    BASE_DIR="$PWD/$EXPERIMENT_NAME"
    backup_dir "$BASE_DIR"
    for ((i = 0; i < repeats; i++)); do
        OUTPUT_DIR="$BASE_DIR/$EXPERIMENT_MODE-failure-experiment-$i"
        mkdir -p "$OUTPUT_DIR"

        log_info "Starting experiment iteration $i, output at $OUTPUT_DIR"

        if [ "$EXPERIMENT_MODE" = "pod" ]; then
            install_chaos_mesh
            log_command kubectl delete podchaos --all || true
        elif [ "$EXPERIMENT_MODE" = "real" ]; then
            setup_autoscaling
            log_autoscaler_events &
            PIDS+=($!)
        elif [ "$EXPERIMENT_MODE" != "node" ]; then
            log_error "Invalid experiment mode: $EXPERIMENT_MODE"
            return 1
        fi

        measure_node_latencies "start"

        log_scheduling_events &
        PIDS+=($!)
        log_node_events &
        PIDS+=($!)
        start_robot_shop
        save_config

        log_info "Saving initial schedule..."
        log_command "kubectl get pods -o wide >\"$OUTPUT_DIR/schedule.log\""
        log_info "Saved initial_schedule"

        get_pod_and_container_ids >"$OUTPUT_DIR/ids_start.log"

        start_loadgenerator

        local start_ts
        start_ts=$(now)
        log_info "Started Loadgenerator at $start_ts"
        case "$EXPERIMENT_MODE" in
        "node")
            inject_node_failure "$start_ts" &
            ;;
        "pod")
            inject_pod_failure "$start_ts" &
            ;;
        "real") ;;
        esac

        attach_to_docker_container

        local end_ts
        end_ts=$(now)
        save_container_stats "$start_ts" "$end_ts"

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

        kill_background_jobs
        measure_node_latencies "end"

        log_success "Experiment iteration $i finished"
    done

    if [ "$EXPERIMENT_MODE" = "real" ]; then
        cleanup_autoscaling
    fi

    rm -r "$HOME/robot-yamls"

    log_success "All experiment iterations complete."
}

main "$@"
