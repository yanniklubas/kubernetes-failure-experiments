#!/usr/bin/env bash

# GLOBAL VARIABLES
APP_REPO="$PWD/robot-shop"
MANIFESTS_PATH="$PWD/manifests"
TEMPLATES_PATH="$MANIFESTS_PATH/robot-shop/templates"

EXPERIMENT_NAME="container_start_times"
BASE_DIR="$PWD/$EXPERIMENT_NAME"

# ++++++++++++++++++++++
# ++ HELPER FUNCTIONS ++
# ++++++++++++++++++++++
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
        git pull
    )

    mkdir -p "$MANIFESTS_PATH"

    echo "Generating helm manifests for robot shop..."

    helm template robot-shop "$APP_REPO/K8s/helm" \
        --output-dir "$MANIFESTS_PATH" \
        --values "$PWD/values.yaml"

    mkdir -p "$BASE_DIR/manifests"
    cp -a "$TEMPLATES_PATH/." "$BASE_DIR/manifests/"

    echo "Applying local storage class..."
    kubectl apply -f "$APP_REPO/K8s/local-storage-class.yml"

    echo "Adding RabbitMQ Operator helm repository..."
    helm repo add rabbitmq https://charts.bitnami.com/bitnami
}

start_application() {
    local services=(
        "mongodb"
        "mysql"
        "rabbitmq"
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
            kubectl delete \
                -f "$TEMPLATES_PATH/$service-deployment.yaml" \
                --now \
                --timeout 1s ||
                true
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
            kubectl apply -f "$TEMPLATES_PATH/$service-deployment.yaml"
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

    if ! kubectl get pods --no-headers 2>/dev/null | grep -q .; then
        echo "Deleting existing robot shop deployment..."

        kubectl delete -f "$TEMPLATES_PATH/redis-statefulset.yaml" || true
        kubectl delete -f "$TEMPLATES_PATH/redis-service.yaml" || true

        delete_services "${services[@]}"

        # RabbitMQ Operator
        kubectl patch rabbitmqclusters.rabbitmq.com rabbitmq \
            --type json \
            --patch='[{"op": "remove", "path": "metadata/finalizers"}]' || true
        kubectl delete pod rabbitmq-server-0 --now || true

        echo "Waiting for all pods to terminate..."
        wait_for_delete "${services[@]}"
    fi

    echo "Cleaning up persistent volumes and persistent volume claims..."

    # Persistent Volume Claims
    for pvc in $(kubectl get pvc -n default -o jsonpath='{.items[*].metadata.name}'); do
        kubectl patch pvc "$pvc" \
            -n default \
            -p '{"metadata": {"finalizers": []}}' \
            --type merge || true
    done
    kubectl delete pvc --all --grace-period=0 --force

    # Persistent Volumes
    for pv in $(kubectl get pv -n default -o jsonpath='{.items[*].metadata.name}'); do
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
    # RabbitMQ Operator install
    helm install rabbitmq-operator \
        rabbitmq/rabbitmq-cluster-operator \
        --version 3.6.6 \
        --values "$PWD/rabbitmq_values.yaml"
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=rabbitmq-cluster-operator --timeout -1s
    kubectl wait --for=condition=Ready pod -l app.kubernetes.io/instance=rabbitmq-operator --timeout -1s

    echo "Applying service: redis"
    kubectl apply -f "$TEMPLATES_PATH/redis-statefulset.yaml"
    kubectl apply -f "$TEMPLATES_PATH/redis-service.yaml"

    apply_services "${services[@]}"

    wait_for_ready "${services[@]}"

    kubectl scale deployment -l service=shipping --replicas=1

    echo "Robot shop is up and running!"
}

save_ready_duration() {
    local services=(
        "mongodb"
        "mysql"
        "rabbitmq"
        "cart"
        "catalogue"
        "dispatch"
        "payment"
        "ratings"
        "shipping"
        "user"
        "web"
    )

    delete_pod_and_wait() {
        local service="$1"
        local pod
        echo "Deleting service: $service"
        pod=$(kubectl get pod -l service="$service" --no-headers | awk '{print $1}')
        echo "$pod"
        kubectl delete \
            pod \
            "$pod"

        echo "Waiting for service $service to terminate"
        kubectl wait --for=delete pod "$pod" --timeout -1s || true
        echo "Service $service terminated"
    }

    wait_for_ready() {
        local service="$1"
        echo "Waiting for service $service to become ready..."
        kubectl wait --for=condition=Ready pod -l "service=$service" --timeout -1s || true
        echo "Service $service is ready"
    }

    local rep="$1"
    local out="$BASE_DIR/container_start_times-${rep}.csv"
    printf "%s\n" "service,ready_time" >"$out"
    local ready_time pod_json
    for service in "${services[@]}"; do
        delete_pod_and_wait "$service"
        sleep 1
        wait_for_ready "$service"
        pod_json=$(kubectl get pod -l service="$service" -o json)
        echo "$pod_json" >"pod.json"
        if [[ $(jq '.items | length' <<<"$pod_json") -eq 0 ]]; then
            printf "%s has no pods!!\n" "$service"
            continue
        fi
        ready_time=$(jq -r '
        .items[0].status as $status |
            ($status.startTime | sub("\\..*";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $start |
            ($status.conditions[] | select(.type == "Ready") | .lastTransitionTime | sub("\\..*";"") | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) as $ready |
            ($ready - $start)
        ' <<<"$pod_json")
        printf "%s,%s\n" "$service" "$ready_time" >>"$out"
    done
}

main() {
    local repeats="${1:-1}"

    backup_dir "$BASE_DIR"
    mkdir -p "$BASE_DIR"

    setup_application

    local i
    for ((i = 0; i < repeats; i++)); do
        echo "Starting experiment iteration $((i + 1))/$repeats..."

        start_application

        save_ready_duration "$i"

        echo "Experiment iteration $((i + 1))/$repeats finished"
    done

    rm -r "$MANIFESTS_PATH"
    echo "All experiment iterations complete!"
}

main "$@"
