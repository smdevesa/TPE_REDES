#!/bin/bash
# Stack de observabilidad de The Store (Prometheus, Loki + Promtail, Tempo, Grafana)
# y comandos para la demo de los casos de uso de la Reentrega.
#
#   ./observability.sh help
set -euo pipefail

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
OBS_DIR="$DIR/observability"
CLUSTER_NAME="the-store"
NODE_CONTAINER="$CLUSTER_NAME-control-plane"
NS_OBS="observability"
NS_APP="the-store"
CHAOS_SERVICES="catalog carts orders checkout"   # ui no tiene endpoints /chaos
APP_URL="http://localhost"

# Versiones de los charts fijadas: una reinstalación da siempre el mismo resultado
PROMETHEUS_CHART_VERSION="29.31.1"
GRAFANA_CHART_VERSION="10.5.15"
LOKI_CHART_VERSION="7.3.0"
PROMTAIL_CHART_VERSION="6.17.1"
TEMPO_CHART_VERSION="1.24.4"

info()    { echo -e "\033[0;34m$*\033[0m"; }
ok()      { echo -e "\033[0;32m$*\033[0m"; }
warn()    { echo -e "\033[1;33m$*\033[0m"; }
fail()    { echo -e "\033[0;31m$*\033[0m" >&2; exit 1; }

require() { for c in "$@"; do command -v "$c" &>/dev/null || fail "Falta '$c' instalado"; done; }

cluster_exists() { kind get clusters 2>/dev/null | grep -q "^$CLUSTER_NAME$"; }

is_chaos_service() { [[ " $CHAOS_SERVICES " == *" $1 "* ]] || fail "Servicio inválido '$1'. Opciones: $CHAOS_SERVICES"; }

# ------------------------------------------------------------------ cluster

cmd_start() {
    require docker kubectl
    docker start "$NODE_CONTAINER" >/dev/null || fail "No existe el cluster. Crealo con ./local.sh create-cluster"
    # Que no vuelva a arrancar solo al prender la compu
    docker update --restart=no "$NODE_CONTAINER" >/dev/null
    info "Esperando a que el nodo esté listo..."
    until kubectl get nodes &>/dev/null; do sleep 2; done
    kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
    info "Esperando a los pods de $NS_APP y $NS_OBS..."
    kubectl wait --for=condition=Ready pods --all -n "$NS_APP" --timeout=300s >/dev/null || warn "Hay pods de $NS_APP sin estar listos"
    kubectl wait --for=condition=Ready pods --all -n "$NS_OBS" --timeout=300s >/dev/null || warn "Hay pods de $NS_OBS sin estar listos"
    ok "Cluster listo. Abrí los paneles con: ./observability.sh ui"
}

cmd_stop() {
    require docker
    docker stop "$NODE_CONTAINER" >/dev/null
    ok "Cluster detenido (no se pierde nada). Volvé a prenderlo con: ./observability.sh start"
}

# ------------------------------------------------------------------ install

load_env() {
    DISCORD_WEBHOOK_URL=""
    if [ -f "$DIR/.env" ]; then
        # shellcheck disable=SC1091
        set -a; source "$DIR/.env"; set +a
    fi
    if [ -z "${DISCORD_WEBHOOK_URL:-}" ]; then
        warn "DISCORD_WEBHOOK_URL no está definido en .env: las alertas no van a llegar a Discord."
        warn "Copiá .env.example a .env, poné el webhook y volvé a correr install."
        DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/0/sin-configurar"
    fi
}

# Crea/actualiza los ConfigMaps y el Secret que Grafana carga por provisioning
apply_grafana_config() {
    load_env
    kubectl create secret generic grafana-discord -n "$NS_OBS" \
        --from-literal=DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create configmap grafana-dashboards -n "$NS_OBS" \
        --from-file="$OBS_DIR/grafana/dashboards" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl create configmap grafana-alerting -n "$NS_OBS" \
        --from-file="$OBS_DIR/grafana/alerting" \
        --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

helm_release() {  # nombre chart versión archivo-values
    info "Instalando/actualizando $1 ($2 $3)..."
    helm upgrade --install "$1" "$2" --version "$3" --history-max 3 -n "$NS_OBS" -f "$OBS_DIR/values/$4" --wait --timeout 5m >/dev/null
}

cmd_install() {
    require kubectl helm
    cluster_exists || fail "No existe el cluster. Crealo con ./local.sh create-cluster"

    info "Repos de Helm..."
    helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
    helm repo update >/dev/null

    kubectl create namespace "$NS_OBS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

    helm_release prometheus prometheus-community/prometheus "$PROMETHEUS_CHART_VERSION" prometheus.yaml
    helm_release loki       grafana/loki                     "$LOKI_CHART_VERSION"       loki.yaml
    helm_release promtail   grafana/promtail                 "$PROMTAIL_CHART_VERSION"   promtail.yaml
    helm_release tempo      grafana/tempo                    "$TEMPO_CHART_VERSION"      tempo.yaml

    apply_grafana_config
    helm_release grafana    grafana/grafana                  "$GRAFANA_CHART_VERSION"    grafana.yaml
    # Los ConfigMaps no disparan un redeploy solos
    kubectl rollout restart deploy/grafana -n "$NS_OBS" >/dev/null
    kubectl rollout status deploy/grafana -n "$NS_OBS" --timeout=180s >/dev/null

    info "Aplicando manifiestos de The Store (variables OpenTelemetry y probes)..."
    kubectl apply -f "$DIR/dist/kubernetes.yaml" -n "$NS_APP" >/dev/null
    kubectl rollout status deploy -n "$NS_APP" --timeout=300s >/dev/null

    ok "Stack instalado."
    cmd_status
}

# Solo recarga tableros y alertas (más rápido que install)
cmd_reload_grafana() {
    apply_grafana_config
    kubectl rollout restart deploy/grafana -n "$NS_OBS" >/dev/null
    kubectl rollout status deploy/grafana -n "$NS_OBS" --timeout=180s >/dev/null
    ok "Tableros y alertas recargados."
}

# Borra métricas, logs, trazas e historial de alertas (todo vive en volúmenes
# emptyDir: al recrear el pod arranca vacío). La configuración no se toca.
cmd_reset_data() {
    require kubectl
    read -p "Se borran métricas, logs, trazas, historial de alertas y los datos en memoria de The Store. ¿Seguir? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
    info "Recreando Prometheus, Loki, Tempo y Grafana..."
    kubectl delete pod -n "$NS_OBS" -l app.kubernetes.io/name=prometheus,app.kubernetes.io/component=server --wait=false >/dev/null
    kubectl delete pod -n "$NS_OBS" loki-0 tempo-0 --wait=false >/dev/null
    kubectl delete pod -n "$NS_OBS" -l app.kubernetes.io/name=grafana --wait=false >/dev/null
    info "Reiniciando The Store (carritos y órdenes están en memoria)..."
    kubectl rollout restart deploy -n "$NS_APP" >/dev/null
    sleep 5
    kubectl rollout status deploy -n "$NS_APP" --timeout=300s >/dev/null || warn "Hay deployments de $NS_APP sin estar listos"
    kubectl wait --for=condition=Ready pods --all -n "$NS_OBS" --timeout=300s >/dev/null || warn "Hay pods de $NS_OBS sin estar listos"
    ok "Datos borrados: todo arranca desde cero."
}

cmd_uninstall() {
    require helm kubectl
    read -p "Se borra el namespace $NS_OBS con todos sus datos. ¿Seguir? (y/N): " -n 1 -r; echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 0
    for r in grafana tempo promtail loki prometheus; do helm uninstall "$r" -n "$NS_OBS" 2>/dev/null || true; done
    kubectl delete namespace "$NS_OBS" --wait=true
    ok "Stack de observabilidad desinstalado."
}

# ------------------------------------------------------------------ status

cmd_status() {
    require kubectl
    info "== Pods de $NS_APP"; kubectl get pods -n "$NS_APP"
    echo; info "== Pods de $NS_OBS"; kubectl get pods -n "$NS_OBS"
    echo; info "== Releases de Helm"; helm list -n "$NS_OBS" 2>/dev/null || true
    echo; info "== Targets de Prometheus (The Store)"
    kubectl exec -n "$NS_OBS" deploy/prometheus-server -c prometheus-server -- \
        wget -qO- 'http://localhost:9090/api/v1/query?query=up{job=~"the-store-.*"}' 2>/dev/null \
        | grep -o '"service":"[a-z]*"[^]]*"[01]"\]' | sed -E 's/"service":"([a-z]+)".*"([01])"\]/  \1 \2/' \
        | sed -e 's/ 1$/ -> UP/' -e 's/ 0$/ -> DOWN/' || warn "  No se pudo consultar Prometheus"
    echo; info "== Caos activo"
    show_chaos_state
}

# ------------------------------------------------------------------ ui

cmd_ui() {
    require kubectl
    info "Port-forwards activos (Ctrl+C para cerrar):"
    echo "  Grafana     http://localhost:3000   (admin / admin)"
    echo "  Prometheus  http://localhost:9090"
    echo "  The Store   $APP_URL"
    trap 'kill 0' EXIT INT TERM
    kubectl port-forward -n "$NS_OBS" svc/grafana 3000:80 >/dev/null &
    kubectl port-forward -n "$NS_OBS" svc/prometheus-server 9090:80 >/dev/null &
    wait
}

# ------------------------------------------------------------------ tráfico

# Simula un usuario: navega el catálogo, agrega al carrito y compra.
# Pasa por los 5 servicios (ui -> catalog, carts, checkout -> orders).
one_purchase() {
    local jar; jar=$(mktemp)
    local c=(curl -s -o /dev/null -b "$jar" -c "$jar" --max-time 15)
    local products=(cc789f85-1476-452a-8100-9e74502198e0 87e89b11-d319-446d-b9be-50adcca5224a
                    4f18544b-70a5-4352-8e19-0d070f46745d 79bce3f3-935f-4912-8c62-0d2f3e059405
                    d27cf49f-b689-4a75-a249-d373e0330bb5)
    local p=${products[$((RANDOM % ${#products[@]}))]}
    "${c[@]}" "$APP_URL/home"
    "${c[@]}" "$APP_URL/catalog"
    "${c[@]}" "$APP_URL/catalog/$p"
    "${c[@]}" -X POST -d "productId=$p" "$APP_URL/cart"
    "${c[@]}" "$APP_URL/cart"
    "${c[@]}" "$APP_URL/checkout"
    local token
    token=$(curl -s -b "$jar" -c "$jar" --max-time 15 -X POST \
        -d "firstName=John&lastName=Doe&email=john_doe@example.com&address1=100+Main+Street&city=Anytown&zipCode=11111&state=CA" \
        "$APP_URL/checkout" | tr '\n' ' ' | grep -oE 'name="token"[^>]*value="[^"]*"' | head -1 | sed -E 's/.*value="([^"]*)"/\1/' || true)
    if [ -n "$token" ]; then
        "${c[@]}" -X POST -d "token=$token" "$APP_URL/checkout/delivery"
        "${c[@]}" -X POST -d "cardHolder=John+Doe&cardNumber=1234567890123456&expiryDate=01/35&cvc=123" "$APP_URL/checkout/payment"
    fi
    rm -f "$jar"
    sleep 1   # ritmo de un usuario real (y evita miles de req/s cuando todo falla rápido)
}

cmd_traffic() {
    local seconds="${1:-300}" users="${2:-3}"
    info "Generando tráfico contra $APP_URL durante ${seconds}s con $users usuarios (Ctrl+C para cortar)..."
    local end=$((SECONDS + seconds))
    trap 'kill 0 2>/dev/null; exit 0' INT TERM
    for _ in $(seq "$users"); do
        ( while [ $SECONDS -lt $end ]; do one_purchase; done ) &
    done
    wait
    ok "Tráfico finalizado."
}

# ------------------------------------------------------------------ caos

# Ejecuta un request contra los endpoints /chaos del servicio vía port-forward
chaos_call() {  # servicio método path
    local svc=$1 method=$2 path=$3 port=$((18000 + RANDOM % 1000))
    kubectl port-forward -n "$NS_APP" "svc/$svc" "$port:80" >/dev/null 2>&1 &
    local pf=$!
    local i
    for i in $(seq 20); do curl -s -o /dev/null "localhost:$port" 2>/dev/null && break; sleep 0.3; done
    local code; code=$(curl -s -o /dev/null -w '%{http_code}' -X "$method" "localhost:$port$path" || true)
    kill $pf 2>/dev/null || true
    wait $pf 2>/dev/null || true
    echo "  $method $svc$path -> HTTP $code"
}

show_chaos_state() {
    local svc lim
    for svc in catalog carts orders checkout ui; do
        lim=$(kubectl get deploy "$svc" -n "$NS_APP" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}' 2>/dev/null || true)
        [ -n "$lim" ] && echo "  $svc: límite de CPU = $lim"
    done
    echo "  (los estados de /chaos/status y /chaos/latency viven en memoria de cada pod; 'chaos reset' los limpia)"
}

cmd_chaos() {
    require kubectl curl
    local action="${1:-}"; shift || true
    case "$action" in
        errors)   # 3.3.1 / 3.3.3
            local svc="${1:-catalog}" code="${2:-500}"; is_chaos_service "$svc"
            info "Forzando HTTP $code en $svc"
            chaos_call "$svc" POST "/chaos/status/$code" ;;
        latency)  # 3.3.2
            local svc="${1:-catalog}" ms="${2:-2000}"; is_chaos_service "$svc"
            info "Agregando ${ms}ms de latencia en $svc"
            chaos_call "$svc" POST "/chaos/latency/$ms" ;;
        cpu)      # 3.3.5
            local svc="${1:-carts}" mcpu="${2:-50}"
            kubectl get deploy "$svc" -n "$NS_APP" >/dev/null || fail "No existe el deployment $svc"
            info "Limitando la CPU de $svc a ${mcpu}m (el pod se recrea con el nuevo límite)"
            # El request no puede superar al límite, así que se bajan los dos
            kubectl set resources "deploy/$svc" -n "$NS_APP" --limits="cpu=${mcpu}m" --requests="cpu=${mcpu}m" >/dev/null
            echo "  Mirá el tablero 'The Store - Infraestructura': throttling, readiness y reinicios." ;;
        reset)
            info "Quitando caos de todos los servicios"
            local svc
            # 1) Límites de CPU (primero, para que los pods vuelvan a estar sanos)
            for svc in catalog carts orders checkout ui; do
                if [ -n "$(kubectl get deploy "$svc" -n "$NS_APP" -o jsonpath='{.spec.template.spec.containers[0].resources.limits.cpu}')" ]; then
                    kubectl patch "deploy/$svc" -n "$NS_APP" --type=json \
                        -p '[{"op":"remove","path":"/spec/template/spec/containers/0/resources/limits/cpu"}]' >/dev/null
                    echo "  $svc: límite de CPU quitado"
                fi
            done
            # Restaura requests y réplicas originales del manifiesto
            kubectl apply -f "$DIR/dist/kubernetes.yaml" -n "$NS_APP" >/dev/null
            kubectl rollout status deploy -n "$NS_APP" --timeout=300s >/dev/null || warn "  Hay deployments que todavía no están listos"
            # 2) Errores y latencia inyectados por /chaos
            for svc in $CHAOS_SERVICES; do
                chaos_call "$svc" DELETE /chaos/status
                chaos_call "$svc" DELETE /chaos/latency
            done
            ok "Listo." ;;
        *) fail "Uso: chaos errors <svc> [código] | chaos latency <svc> <ms> | chaos cpu <svc> <milicores> | chaos reset" ;;
    esac
}

# ------------------------------------------------------------------ help

show_help() {
    cat <<EOF
Uso: ./observability.sh <comando> [args]

Cluster
  start                     Prende el cluster Kind (ya no arranca solo con la compu)
  stop                      Apaga el cluster (no se pierde nada)

Stack de observabilidad
  install                   Instala/actualiza Prometheus, Loki, Promtail, Tempo y Grafana
                            + tableros, alertas, Discord y manifiestos de The Store
  reload-grafana            Recarga solo tableros y alertas tras editar los archivos
  reset-data                Borra métricas, logs, trazas y alertas: datos desde cero
  uninstall                 Borra el namespace $NS_OBS
  status                    Pods, releases, targets de Prometheus y caos activo
  ui                        Port-forward de Grafana (:3000) y Prometheus (:9090)

Demo
  traffic [seg] [usuarios]  Usuarios simulados comprando en $APP_URL (default 300s, 3)
  chaos errors <svc> [code] 3.3.1/3.3.3  POST /chaos/status/<code> (default catalog 500)
  chaos latency <svc> <ms>  3.3.2        POST /chaos/latency/<ms>  (default catalog 2000)
  chaos cpu <svc> <m>       3.3.5        Limita la CPU del deployment (default carts 50m)
  chaos reset               Quita todo el caos (DELETE /chaos/* y límites de CPU)

  Servicios con /chaos: $CHAOS_SERVICES
EOF
}

case "${1:-help}" in
    start) cmd_start ;;
    stop) cmd_stop ;;
    install) cmd_install ;;
    reload-grafana) cmd_reload_grafana ;;
    reset-data) cmd_reset_data ;;
    uninstall) cmd_uninstall ;;
    status) cmd_status ;;
    ui) cmd_ui ;;
    traffic) shift; cmd_traffic "$@" ;;
    chaos) shift; cmd_chaos "$@" ;;
    help|-h|--help) show_help ;;
    *) show_help; exit 1 ;;
esac
