#!/usr/bin/env bash
# ============================================================================
# run.sh — Harness de benchmark Go vs Rust para router-agent
#
# Dos modos:
#   --target mock-sshd    (default) Alta concurrencia contra un SSH server
#                          mínimo containerizado que simula la latencia del
#                          router real, SIN tocar hardware físico.
#   --target real-router  Baja concurrencia, número acotado de requests,
#                          contra un agente YA corriendo (just router-agent-run-go
#                          / -rust) apuntando al router real. Este script NO
#                          construye ni levanta nada en ese modo — solo mide.
#
# Requiere: podman, hey (https://github.com/rakyll/hey), ssh-keygen, jq.
#
# Uso:
#   router-agent/bench/run.sh --target mock-sshd [--impl go|rust|both]
#   router-agent/bench/run.sh --target real-router --url http://localhost:8443 [--requests 20] [--concurrency 2]
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
MOCK_DIR="${SCRIPT_DIR}/mock-sshd"
NETWORK="router-agent-bench"

TARGET="mock-sshd"
IMPL="both"
MOCK_DURATION="15s"
MOCK_CONCURRENCY="50"
REAL_REQUESTS="20"
REAL_CONCURRENCY="2"
REAL_URL="http://localhost:8443"
TOKEN="bench-token-$(date +%s)"

_log() { echo "[bench] $*"; }
_err() { echo "[bench] ERROR: $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --target) TARGET="${2:?}"; shift 2 ;;
        --impl) IMPL="${2:?}"; shift 2 ;;
        --duration) MOCK_DURATION="${2:?}"; shift 2 ;;
        --concurrency) MOCK_CONCURRENCY="${2:?}"; REAL_CONCURRENCY="${2}"; shift 2 ;;
        --requests) REAL_REQUESTS="${2:?}"; shift 2 ;;
        --url) REAL_URL="${2:?}"; shift 2 ;;
        -h|--help)
            echo "Uso: $0 --target mock-sshd|real-router [--impl go|rust|both] [--duration 15s] [--concurrency N] [--requests N] [--url http://host:port]"
            exit 0
            ;;
        *) _err "Argumento desconocido: $1"; exit 1 ;;
    esac
done

for bin in podman hey ssh-keygen jq; do
    if ! command -v "${bin}" &>/dev/null; then
        _err "'${bin}' no encontrado en PATH."
        [ "${bin}" = "hey" ] && echo "   Instalar: go install github.com/rakyll/hey@latest  (o) brew install hey"
        exit 1
    fi
done

mkdir -p "${RESULTS_DIR}"
DATE_TAG="$(date +%Y%m%d-%H%M%S)"

# ---------------------------------------------------------------------------
# real-router: mide un agente que YA está corriendo. No orquesta nada más.
# ---------------------------------------------------------------------------
_run_real_router() {
    _log "Target: real-router — ${REAL_URL} (requests=${REAL_REQUESTS} concurrency=${REAL_CONCURRENCY})"
    _log "Asume un agente ya corriendo (just router-agent-run-go / -rust) con su propio token."
    read -r -p "Token API del agente (X-Router-Agent-Token): " -s RUN_TOKEN
    echo ""

    local out="${RESULTS_DIR}/${DATE_TAG}-real-router.txt"
    hey -n "${REAL_REQUESTS}" -c "${REAL_CONCURRENCY}" -m GET \
        -H "X-Router-Agent-Token: ${RUN_TOKEN}" \
        "${REAL_URL}/v1/status" | tee "${out}"
    _log "Resultado guardado en ${out}"
    _log "Nota: --target real-router usa pocos requests a propósito para no saturar un router embebido."
}

# ---------------------------------------------------------------------------
# mock-sshd: orquesta mock-sshd + el/los agente(s), corre carga, mide, limpia.
# ---------------------------------------------------------------------------
_bench_keypair() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    ssh-keygen -q -t ed25519 -N "" -f "${tmpdir}/bench-key" -C "bench@router-agent" > /dev/null
    # Ambas imágenes corren como UID no-root (65532) dentro del contenedor;
    # sin esto, sshclient falla con "permission denied" al leer la llave.
    chmod 644 "${tmpdir}/bench-key"
    echo "${tmpdir}"
}

_build_mock_sshd() {
    local keydir="$1"
    cp "${keydir}/bench-key.pub" "${MOCK_DIR}/bench-key.pub"
    podman build -q -t router-agent-mock-sshd -f "${MOCK_DIR}/Containerfile" "${MOCK_DIR}" > /dev/null
    rm -f "${MOCK_DIR}/bench-key.pub"
}

_sample_stats() {
    # Muestrea RSS/CPU de un contenedor cada segundo mientras exista el archivo lock.
    local container="$1" out="$2" lock="$3"
    : > "${out}"
    while [ -f "${lock}" ]; do
        podman stats --no-stream --format json "${container}" 2>/dev/null >> "${out}" || true
        sleep 1
    done
}

_bench_one_impl() {
    local impl="$1" mock_host="$2" mock_port="$3" known_hosts="$4" keydir="$5"
    local image="router-agent-${impl}:dev"

    if ! podman image exists "${image}"; then
        _log "Imagen ${image} no existe — corre 'just router-agent-build-${impl}' primero. Saltando ${impl}."
        return 0
    fi

    _log "=== ${impl} ==="
    local container="router-agent-bench-${impl}"
    podman rm -f "${container}" &>/dev/null || true

    podman run -d --rm --name "${container}" \
        --network "${NETWORK}" \
        -p 127.0.0.1::8443 \
        -v "${keydir}/bench-key:/secrets/captive-agent-key:ro" \
        -v "${known_hosts}:/secrets/router-known-hosts:ro" \
        -e ROUTER_AGENT_API_TOKEN="${TOKEN}" \
        -e ROUTER_AGENT_ALLOWED_CIDRS="0.0.0.0/0" \
        -e ROUTER_AGENT_SSH_HOST="${mock_host}" \
        -e ROUTER_AGENT_SSH_PORT="${mock_port}" \
        -e ROUTER_AGENT_SSH_KEY_PATH=/secrets/captive-agent-key \
        -e ROUTER_AGENT_SSH_KNOWN_HOSTS_PATH=/secrets/router-known-hosts \
        "${image}" > /dev/null

    local agent_port agent_url
    agent_port="$(podman port "${container}" 8443/tcp | cut -d: -f2)"
    agent_url="http://localhost:${agent_port}"
    _log "Esperando /healthz de ${impl} en ${agent_url}..."
    for _ in $(seq 1 20); do
        curl -sf "${agent_url}/healthz" > /dev/null 2>&1 && break
        sleep 0.5
    done

    local stats_out="${RESULTS_DIR}/${DATE_TAG}-${impl}-stats.jsonl"
    local lock; lock="$(mktemp)"
    _sample_stats "${container}" "${stats_out}" "${lock}" &
    local sampler_pid=$!

    local hey_out="${RESULTS_DIR}/${DATE_TAG}-${impl}-mock-sshd.txt"
    hey -z "${MOCK_DURATION}" -c "${MOCK_CONCURRENCY}" -m POST \
        -H "X-Router-Agent-Token: ${TOKEN}" -H "Content-Type: application/json" \
        -d '{"ip":"10.99.0.1","timeout_min":1}' \
        "${agent_url}/v1/allow" | tee "${hey_out}"

    rm -f "${lock}"
    wait "${sampler_pid}" 2>/dev/null || true

    local image_size
    image_size="$(podman images --format '{{.Size}}' "${image}" | head -1)"

    jq -n \
        --arg impl "${impl}" \
        --arg target "mock-sshd" \
        --arg date "${DATE_TAG}" \
        --arg image_size "${image_size}" \
        --arg hey_output "$(cat "${hey_out}")" \
        '{impl: $impl, target: $target, date: $date, image_size: $image_size, hey_output: $hey_output}' \
        > "${RESULTS_DIR}/${DATE_TAG}-${impl}-mock-sshd.json"

    podman rm -f "${container}" &>/dev/null || true
    _log "${impl}: resultados en ${RESULTS_DIR}/${DATE_TAG}-${impl}-mock-sshd.json"
}

_run_mock_sshd() {
    _log "Target: mock-sshd — duration=${MOCK_DURATION} concurrency=${MOCK_CONCURRENCY} impl=${IMPL}"

    podman network exists "${NETWORK}" || podman network create "${NETWORK}" > /dev/null

    local keydir known_hosts mock_container
    keydir="$(_bench_keypair)"
    _log "Construyendo mock-sshd..."
    _build_mock_sshd "${keydir}"

    mock_container="router-agent-bench-mock-sshd"
    podman rm -f "${mock_container}" &>/dev/null || true
    podman run -d --rm --name "${mock_container}" --network "${NETWORK}" \
        router-agent-mock-sshd > /dev/null

    # known_hosts para los agentes (dentro de la red podman, por nombre de contenedor)
    known_hosts="${keydir}/known_hosts"
    for _ in $(seq 1 20); do
        ssh-keyscan -T 2 "${mock_container}" > "${known_hosts}" 2>/dev/null && [ -s "${known_hosts}" ] && break
        sleep 0.5
    done

    trap 'podman rm -f "${mock_container}" router-agent-bench-go router-agent-bench-rust &>/dev/null || true; podman network rm "${NETWORK}" &>/dev/null || true; rm -rf "${keydir}"' EXIT

    if [ "${IMPL}" = "go" ] || [ "${IMPL}" = "both" ]; then
        _bench_one_impl "go" "${mock_container}" "22" "${known_hosts}" "${keydir}"
    fi
    if [ "${IMPL}" = "rust" ] || [ "${IMPL}" = "both" ]; then
        _bench_one_impl "rust" "${mock_container}" "22" "${known_hosts}" "${keydir}"
    fi

    _generate_report
}

_generate_report() {
    local report="${RESULTS_DIR}/REPORT.md"
    {
        echo "# router-agent bench — ${DATE_TAG}"
        echo ""
        echo "| impl | image size | hey summary |"
        echo "|---|---|---|"
        for impl in go rust; do
            local f="${RESULTS_DIR}/${DATE_TAG}-${impl}-mock-sshd.json"
            if [ -f "${f}" ]; then
                local size summary
                size="$(jq -r '.image_size' "${f}")"
                summary="$(jq -r '.hey_output' "${f}" | grep -E 'Requests/sec|50%|95%|99%' | tr '\n' ' ' | sed 's/|/\\|/g')"
                echo "| ${impl} | ${size} | ${summary} |"
            fi
        done
        echo ""
        echo "Ver los \`.txt\`/\`.json\` junto a este reporte para el detalle completo de cada corrida."
        echo ""
        echo "**La decisión de qué implementación conservar es manual** — revisa estos números y decide."
    } > "${report}"
    _log "Reporte: ${report}"
}

case "${TARGET}" in
    mock-sshd) _run_mock_sshd ;;
    real-router) _run_real_router ;;
    *) _err "Target desconocido: ${TARGET} (usa mock-sshd o real-router)"; exit 1 ;;
esac
