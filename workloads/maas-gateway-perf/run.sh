#!/bin/bash -e

set -e

source env.sh

OS=$(uname -s)
HARDWARE=$(uname -m)

# ============================================================
# Phase 1: Download kube-burner-ocp
# ============================================================

download_kube_burner() {
  if [[ -z ${KUBE_BURNER_URL} ]]; then
    KUBE_BURNER_URL="https://github.com/vishnuchalla/kube-burner-ocp/releases/download/v${KUBE_BURNER_VERSION}/kube-burner-ocp-V${KUBE_BURNER_VERSION}-${OS}-${HARDWARE}.tar.gz"
  fi
  curl --fail --retry 8 --retry-all-errors -sS -L "${KUBE_BURNER_URL}" | tar -xzC "${KUBE_DIR}/" kube-burner-ocp
}

install_dependencies() {
  if ! command -v kustomize &>/dev/null || \
     ! kustomize version 2>/dev/null | grep -qE 'v[5-9]\.[7-9]|v[5-9]\.[1-9][0-9]|v[6-9]\.'; then
    echo "Installing kustomize v5.7.0..."
    local kust_os kust_arch
    kust_os=$(uname -s | tr '[:upper:]' '[:lower:]')
    kust_arch=$(uname -m)
    [[ "${kust_arch}" == "x86_64" ]] && kust_arch="amd64"
    [[ "${kust_arch}" == "aarch64" || "${kust_arch}" == "arm64" ]] && kust_arch="arm64"
    curl --fail --retry 3 -sS -L \
      "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv5.7.0/kustomize_v5.7.0_${kust_os}_${kust_arch}.tar.gz" \
      | tar -xzC "${KUBE_DIR}/"
    export PATH="${KUBE_DIR}:${PATH}"
  fi

  if ! command -v envsubst &>/dev/null; then
    echo "Installing envsubst (gettext)..."
    if command -v brew &>/dev/null; then
      brew install gettext 2>/dev/null || true
    elif command -v dnf &>/dev/null; then
      dnf install -y gettext 2>/dev/null || true
    elif command -v apt-get &>/dev/null; then
      apt-get install -y gettext-base 2>/dev/null || true
    fi
  fi
}

echo "Installing dependencies..."
install_dependencies

echo "Downloading kube-burner-ocp v${KUBE_BURNER_VERSION}..."
download_kube_burner

# ============================================================
# Cleanup MaaS Platform (for re-runs or teardown)
# ============================================================

cleanup_maas_platform() {
  echo "Cleaning up MaaS platform..."

  local MAAS_NAMESPACES="ai-tenants cert-manager cert-manager-operator kuadrant-system \
    models-as-a-service odh-ai-gateway-infra redhat-ai-gateway-infra \
    opendatahub opendatahub-monitoring \
    redhat-ods-applications redhat-ods-operator redhat-ods-monitoring \
    rh-connectivity-link openshift-lws-operator maas-perf-test"

  # Strip finalizers from CSVs first, then delete OLM resources
  for ns in ${MAAS_NAMESPACES}; do
    for csv in $(oc get csv -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      oc patch csv "$csv" -n "$ns" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done
    oc delete subscription --all -n "$ns" --ignore-not-found --timeout=30s 2>/dev/null || true
    oc delete csv --all -n "$ns" --ignore-not-found --timeout=10s 2>/dev/null || true
    oc delete installplan --all -n "$ns" --ignore-not-found --timeout=10s 2>/dev/null || true
  done

  # AllNamespaces operators (cert-manager, kuadrant, ODH, LWS) copy CSVs to every namespace.
  # Orphaned copies cause "constraints not satisfiable" on re-deploy. Clean them cluster-wide.
  for csv_pattern in cert-manager-operator kuadrant-operator authorino-operator limitador-operator dns-operator opendatahub-operator leader-worker-set; do
    for csv_line in $(oc get csv -A --no-headers 2>/dev/null | grep "$csv_pattern" | awk '{print $1 "/" $2}'); do
      local csv_ns="${csv_line%%/*}" csv_name="${csv_line#*/}"
      oc patch csv "$csv_name" -n "$csv_ns" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
      oc delete csv "$csv_name" -n "$csv_ns" --ignore-not-found --timeout=10s 2>/dev/null || true
    done
  done

  # Remove bootstrap annotation so the controller re-creates the default tenant on next deploy
  oc annotate configs.maas.opendatahub.io default maas.opendatahub.io/default-aitenant-bootstrapped- 2>/dev/null || true

  # Strip finalizers from MaaS CRs that block namespace deletion when controllers are gone
  for crd in aitenant maastenantconfig maasauthpolicy maassubscription maasmodelref llminferenceserviceconfig; do
    for item in $(oc get "$crd" -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
      local item_ns="${item%/*}" item_name="${item#*/}"
      oc patch "$crd" "$item_name" -n "$item_ns" --type=merge -p '{"metadata":{"finalizers":[]}}' 2>/dev/null || true
    done
  done

  # Delete CRs that hold finalizers on namespace-scoped objects
  oc delete datasciencecluster --all --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete dscinitialization --all --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete kuadrant --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete authpolicy --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete tokenratelimitpolicy --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete maastenantconfig --all -A --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete aitenant --all -A --ignore-not-found --timeout=30s 2>/dev/null || true

  # Delete dead webhooks that block namespace cleanup
  oc get validatingwebhookconfiguration -o name 2>/dev/null | grep -iE "kserve|llm|maas|opendatahub|datasciencecluster|dscinitialization" | xargs oc delete --ignore-not-found 2>/dev/null || true
  oc get mutatingwebhookconfiguration -o name 2>/dev/null | grep -iE "kserve|llm|maas|opendatahub|datasciencecluster|dscinitialization" | xargs oc delete --ignore-not-found 2>/dev/null || true

  # Delete gateway resources
  oc delete gateway maas-default-gateway -n openshift-ingress --ignore-not-found --timeout=30s 2>/dev/null || true
  oc delete gatewayclass openshift-default --ignore-not-found --timeout=30s 2>/dev/null || true

  # Force-delete namespaces
  for ns in ${MAAS_NAMESPACES}; do
    if oc get ns "$ns" &>/dev/null; then
      oc delete ns "$ns" --ignore-not-found --timeout=60s 2>/dev/null || {
        echo "Force-removing finalizers from stuck namespace: $ns"
        oc get ns "$ns" -o json | jq '.spec.finalizers = []' | oc replace --raw "/api/v1/namespaces/$ns/finalize" -f - 2>/dev/null || true
      }
    fi
  done

  # Remove stale clone
  rm -rf /tmp/models-as-a-service
  echo "Cleanup complete"
}

# ============================================================
# Phase 2: Deploy MaaS Platform
# ============================================================

deploy_maas_platform() {
  echo "Deploying MaaS platform with operator type: ${OPERATOR_TYPE}"

  local maas_dir="/tmp/models-as-a-service"
  if [[ ! -d "${maas_dir}" ]]; then
    git clone --branch "${MAAS_REF}" --depth 1 \
      https://github.com/opendatahub-io/models-as-a-service.git "${maas_dir}"
  fi

  if [[ "${OPERATOR_TYPE}" == "rhoai" ]]; then
    INFRA_NS="redhat-ai-gateway-infra"
  else
    INFRA_NS="odh-ai-gateway-infra"
  fi

  (
    for i in $(seq 1 120); do
      if oc get secret maas-db-config -n "${INFRA_NS}" &>/dev/null; then
        db_url=$(oc get secret maas-db-config -n "${INFRA_NS}" -o jsonpath='{.data.DB_CONNECTION_URL}' | base64 -d)
        if [[ "${db_url}" == *"sslmode=require"* ]]; then
          echo "Patching maas-db-config: sslmode=require to sslmode=disable"
          oc patch secret maas-db-config -n "${INFRA_NS}" --type=merge \
            -p "{\"stringData\":{\"DB_CONNECTION_URL\":\"${db_url/sslmode=require/sslmode=disable}\"}}"
          oc rollout restart deployment/maas-api -n "${INFRA_NS}" 2>/dev/null || true
        fi
        break
      fi
      sleep 5
    done
  ) &
  local PATCH_PID=$!

  pushd "${maas_dir}"
  OPERATOR_CHANNEL="${OPERATOR_CHANNEL}" ./scripts/deploy.sh --operator-type "${OPERATOR_TYPE}"
  local deploy_rc=$?
  popd

  kill $PATCH_PID 2>/dev/null || true
  wait $PATCH_PID 2>/dev/null || true

  if [[ $deploy_rc -ne 0 ]]; then
    echo "ERROR: MaaS deploy.sh failed (exit code: $deploy_rc)"
    return 1
  fi

  echo "Waiting for maas-api deployment in ${INFRA_NS}..."
  oc wait --for=condition=Available --timeout=300s \
    deployment/maas-api -n "${INFRA_NS}" || {
      echo "ERROR: maas-api not ready after 300s"
      oc get pods -n "${INFRA_NS}" -l app.kubernetes.io/name=maas-api
      return 1
    }

  echo "Waiting for gateway..."
  oc wait --for=condition=Programmed --timeout=120s \
    gateway/maas-default-gateway -n openshift-ingress || {
      echo "ERROR: Gateway not ready after 120s"
      oc get gateway -n openshift-ingress
      return 1
    }
}

if ! deploy_maas_platform; then
  echo "ERROR: MaaS platform deployment failed, aborting benchmark"
  exit 1
fi

# ============================================================
# Phase 3: Register models for gateway benchmarks
# ============================================================

register_test_models() {
  echo "Registering test models for gateway benchmarks..."
  local MODEL_NS="llm"
  local TENANT_NS="models-as-a-service"

  oc create ns "${MODEL_NS}" 2>/dev/null || true

  # Deploy simulator in model namespace
  cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: llm-d-inference-sim
  namespace: ${MODEL_NS}
  labels:
    app: llm-d-inference-sim
spec:
  replicas: 1
  selector:
    matchLabels:
      app: llm-d-inference-sim
  template:
    metadata:
      labels:
        app: llm-d-inference-sim
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: simulator
        image: quay.io/rh-ee-aharush/llm-d-inference-sim:multi-provider
        imagePullPolicy: Always
        args:
        - "--model"
        - "gpt-4o-openai"
        - "--served-model-name"
        - "gpt-4o-openai"
        - "gpt-4o-azure"
        - "gpt-4o-bedrock"
        - "claude-sonnet-anthropic"
        - "claude-sonnet-vertex"
        - "--port"
        - "8000"
        - "--mode"
        - "random"
        - "--providers"
        - "anthropic,azure,bedrock,vertexai"
        - "--max-model-len"
        - "8192"
        - "--max-num-seqs"
        - "1000"
        - "--time-to-first-token"
        - "1"
        - "--inter-token-latency"
        - "1"
        - "--deterministic-tokens"
        ports:
        - containerPort: 8000
          name: http
          protocol: TCP
        resources:
          requests:
            cpu: "500m"
            memory: 512Mi
        readinessProbe:
          httpGet:
            path: /ready
            port: 8000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
          initialDelaySeconds: 10
          periodSeconds: 30
---
apiVersion: v1
kind: Service
metadata:
  name: llm-d-inference-sim
  namespace: ${MODEL_NS}
spec:
  type: ClusterIP
  selector:
    app: llm-d-inference-sim
  ports:
  - port: 8000
    targetPort: 8000
    protocol: TCP
    name: http
EOF

  echo "Waiting for simulator to be ready..."
  oc wait --for=condition=Available --timeout=120s deployment/llm-d-inference-sim -n "${MODEL_NS}" || {
    echo "ERROR: Simulator not ready"
    return 1
  }

  local PROVIDERS_LIST
  IFS=',' read -ra PROVIDERS_LIST <<< "${PROVIDERS}"

  # Create ExternalModel + MaaSModelRef + Secret + HTTPRoute per provider
  for provider in "${PROVIDERS_LIST[@]}"; do
    local provider_type="openai"
    case "$provider" in
      *azure*)    provider_type="azure-openai" ;;
      *bedrock*)  provider_type="bedrock" ;;
      *anthropic*) provider_type="anthropic" ;;
      *vertex*)   provider_type="vertexai" ;;
    esac

    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${provider}-creds
  namespace: ${MODEL_NS}
  labels:
    inference.networking.k8s.io/bbr-managed: "true"
    inference.llm-d.ai/ipp-managed: "true"
type: Opaque
stringData:
  api-key: "dummy-perf-test-key"
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: ExternalModel
metadata:
  name: ${provider}
  namespace: ${MODEL_NS}
  annotations:
    maas.opendatahub.io/tls: "false"
    maas.opendatahub.io/port: "8000"
spec:
  provider: ${provider_type}
  endpoint: llm-d-inference-sim.${MODEL_NS}.svc.cluster.local
  targetModel: ${provider}
  credentialRef:
    name: ${provider}-creds
---
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSModelRef
metadata:
  name: ${provider}
  namespace: ${MODEL_NS}
spec:
  modelRef:
    kind: ExternalModel
    name: ${provider}
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: perf-${provider}
  namespace: ${MODEL_NS}
spec:
  parentRefs:
  - group: gateway.networking.k8s.io
    kind: Gateway
    name: maas-default-gateway
    namespace: openshift-ingress
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /${provider}/
    backendRefs:
    - name: llm-d-inference-sim
      port: 8000
    filters:
    - type: URLRewrite
      urlRewrite:
        path:
          type: ReplacePrefixMatch
          replacePrefixMatch: /
  - matches:
    - headers:
      - name: X-Gateway-Model-Name
        type: Exact
        value: ${provider}
      path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: llm-d-inference-sim
      port: 8000
EOF
  done

  # MaaSAuthPolicy for all models
  local AUTH_REFS=""
  for provider in "${PROVIDERS_LIST[@]}"; do
    AUTH_REFS+="  - name: ${provider}"$'\n'"    namespace: ${MODEL_NS}"$'\n'
  done

  cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSAuthPolicy
metadata:
  name: perf-access
  namespace: ${TENANT_NS}
spec:
  modelRefs:
${AUTH_REFS}  subjects:
    groups:
    - name: "system:authenticated"
EOF

  # MaaSSubscription with high rate limits
  local SUB_REFS=""
  for provider in "${PROVIDERS_LIST[@]}"; do
    SUB_REFS+="  - name: ${provider}"$'\n'"    namespace: ${MODEL_NS}"$'\n'"    tokenRateLimits:"$'\n'"    - limit: 1000000000"$'\n'"      window: 1m"$'\n'
  done

  cat <<EOF | oc apply -f -
apiVersion: maas.opendatahub.io/v1alpha1
kind: MaaSSubscription
metadata:
  name: perf-benchmark
  namespace: ${TENANT_NS}
spec:
  owner:
    groups:
    - name: "system:authenticated"
  modelRefs:
${SUB_REFS}
EOF

  # Wait for reconciliation
  echo "Waiting for model registration to reconcile..."
  sleep 20

  # Patch the broken ExternalName routing created by the reconciler
  for provider in "${PROVIDERS_LIST[@]}"; do
    oc annotate externalmodel.maas.opendatahub.io "${provider}" -n "${MODEL_NS}" \
      opendatahub.io/managed=false --overwrite 2>/dev/null || true

    for route in "${provider}" "maas-${provider}"; do
      if oc get httproute "${route}" -n "${MODEL_NS}" &>/dev/null; then
        oc get httproute "${route}" -n "${MODEL_NS}" -o json | \
          jq '.spec.rules[].backendRefs = [{"name":"llm-d-inference-sim","port":8000,"kind":"Service","group":""}]' | \
          oc replace -f - 2>/dev/null || true
      fi
    done

    if oc get destinationrule "${provider}" -n "${MODEL_NS}" &>/dev/null; then
      oc patch destinationrule "${provider}" -n "${MODEL_NS}" --type=merge \
        -p '{"spec":{"trafficPolicy":{"tls":{"mode":"DISABLE"}}}}' 2>/dev/null || true
    fi
  done

  echo "Model registration complete"
}

register_test_models

# ============================================================
# Phase 4: Determine endpoints
# ============================================================

GATEWAY_HOSTNAME=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].hostname}' 2>/dev/null)
GATEWAY_PORT=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].port}' 2>/dev/null || echo "443")
GATEWAY_PROTOCOL=$(oc get gateway maas-default-gateway -n openshift-ingress \
  -o jsonpath='{.spec.listeners[0].protocol}' 2>/dev/null || echo "HTTPS")
GATEWAY_IP=$(oc get svc -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=maas-default-gateway \
  -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null)
if [[ "${GATEWAY_PROTOCOL}" == "HTTPS" ]]; then
  GATEWAY_HOST="https://${GATEWAY_HOSTNAME}:${GATEWAY_PORT}"
else
  GATEWAY_HOST="http://${GATEWAY_HOSTNAME}:${GATEWAY_PORT}"
fi
SIMULATOR_HOST="http://llm-d-inference-sim.llm.svc.cluster.local:8000"

echo "Gateway: ${GATEWAY_HOST}"
echo "Gateway IP: ${GATEWAY_IP}"
echo "Simulator: ${SIMULATOR_HOST}"

# ============================================================
# Phase 4: Run kube-burner-ocp benchmark
# ============================================================

cmd="${KUBE_DIR}/kube-burner-ocp maas-gateway-perf"
cmd+=" --log-level=${LOG_LEVEL}"
cmd+=" --qps=${QPS} --burst=${BURST} --gc=${GC}"
cmd+=" --uuid ${UUID}"
cmd+=" --gateway-host=${GATEWAY_HOST}"
cmd+=" --gateway-ip=${GATEWAY_IP}"
cmd+=" --simulator-host=${SIMULATOR_HOST}"
cmd+=" --providers=${PROVIDERS}"
cmd+=" --payload-sizes=${PAYLOAD_SIZES}"
cmd+=" --concurrency-levels=${CONCURRENCY_LEVELS}"
cmd+=" --benchmark-duration=${BENCHMARK_DURATION}"
cmd+=" --warmup=${WARMUP}"
cmd+=" --guidellm-image=${GUIDELLM_IMAGE}"
cmd+=" --samples=${SAMPLES}"
cmd+=" --parallelism=${PARALLELISM}"
cmd+=" --pause=${PAUSE}"
cmd+=" ${EXTRA_FLAGS}"

if [[ -n ${ES_SERVER} ]]; then
  cmd+=" --es-server=${ES_SERVER} --es-index=${ES_INDEX}"
fi

echo "$UUID" >> /tmp/"${WORKLOAD}"-uuid.txt

set +e

redacted_cmd=${cmd}
if [[ -n ${ES_SERVER} ]]; then
  redacted_cmd=${redacted_cmd//"${ES_SERVER}"/<redacted-es-server>}
fi
echo "${redacted_cmd}"

JOB_START=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
$cmd
exit_code=$?
JOB_END=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

if [ $exit_code -eq 0 ]; then
  JOB_STATUS="success"
else
  JOB_STATUS="failure"
fi

# ============================================================
# Phase 5: Collect artifacts
# ============================================================

if [[ -n ${ARTIFACT_DIR} ]]; then
  echo "Copying results to artifact directory..."
  METRICS_FOLDER="collected-metrics-${UUID}"
  if [[ -d "${METRICS_FOLDER}" ]]; then
    cp -r "${METRICS_FOLDER}" "${ARTIFACT_DIR}/" 2>/dev/null || true
  fi
fi

# ============================================================
# Phase 6: Index CI metadata
# ============================================================

env JOB_START="$JOB_START" JOB_END="$JOB_END" JOB_STATUS="$JOB_STATUS" \
  UUID="$UUID" WORKLOAD="$WORKLOAD" ES_SERVER="$ES_SERVER" \
  ../../utils/index.sh

exit $exit_code
