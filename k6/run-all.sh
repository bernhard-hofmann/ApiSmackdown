#!/usr/bin/env bash
# Builds, starts, benchmarks and stops each server in turn, so only one
# server runs at a time.
#
#   k6/run-all.sh             # run the benchmark
#   k6/run-all.sh --check     # start and stop each server, no k6
#
# Environment (all optional):
#   TARGETS      servers to test, in order
#                (default: go node node-cluster dotnet python rust)
#   SCENARIO     steady (default) or ramp
#   RUNS         saved runs per server after one warm-up run (default: 3)
#   NODE_BIN     node binary (default: /opt/node-26/bin/node if present, else node)
#   WORKERS      worker processes for node-cluster and python (default: one per core)
#   SERVER_CPUS  pin servers to these cores, e.g. 0-3 (uses taskset)
#   K6_CPUS      pin k6 to these cores, e.g. 4-7 (uses taskset)
#
# Each run's summary goes to results/<target>-<scenario>-<n>.json, the
# versions and machine details to results/info/<target>-<scenario>.json, and
# server output to results/logs/<target>.log. At the end, k6/chart.js draws
# results/chart-<scenario>.svg from every result saved for that scenario
# (set CHART_NOTES to a text file to add your own notes to it).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

TARGETS="${TARGETS:-go node node-cluster dotnet python rust}"
WORKERS="${WORKERS:-$(nproc)}"
SCENARIO="${SCENARIO:-steady}"
RUNS="${RUNS:-3}"
if [[ -z "${NODE_BIN:-}" ]]; then
    if [[ -x /opt/node-26/bin/node ]]; then NODE_BIN=/opt/node-26/bin/node; else NODE_BIN=node; fi
fi

mkdir -p results/logs

port_of() {
    case "$1" in
        go) echo 3000 ;;
        node|node-cluster) echo 3001 ;;
        dotnet) echo 3002 ;;
        python) echo 3003 ;;
        rust) echo 3004 ;;
        *) echo "Unknown target: $1" >&2; exit 1 ;;
    esac
}

pin() {  # pin <cpus> <command...>
    local cpus="$1"; shift
    if [[ -n "$cpus" ]]; then taskset -c "$cpus" "$@"; else "$@"; fi
}

build() {
    case "$1" in
        go)
            echo "--- building Go"
            (cd go-stdlib && go build -o server .) ;;
        node|node-cluster)
            if [[ ! -d node-express/node_modules ]]; then
                echo "--- installing Node dependencies"
                (cd node-express && PATH="$(dirname "$NODE_BIN"):$PATH" npm ci --no-fund --no-audit)
            fi ;;
        dotnet)
            echo "--- building .NET (Release)"
            (cd dotnet-10 && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build -c Release -v quiet -nologo) ;;
        python)
            echo "--- installing Python dependencies"
            (cd python-fastapi && uv sync --frozen --quiet) ;;
        rust)
            echo "--- building Rust (release)"
            (cd rust-axum && cargo build --release --quiet) ;;
    esac
}

SERVER_PID=""
SERVER_PREFIX=()
[[ -n "${SERVER_CPUS:-}" ]] && SERVER_PREFIX=(taskset -c "$SERVER_CPUS")

# Job control gives every background job its own process group, so stopping
# a server also stops any workers it started (e.g. the Node cluster).
set -m

start_server() {
    local target="$1" log="$ROOT/results/logs/$1.log"
    # Start each server directly, not via go run / npm / dotnet run, so the
    # recorded PID is the server itself.
    case "$target" in
        go)           (cd go-stdlib && exec "${SERVER_PREFIX[@]}" ./server) >"$log" 2>&1 & ;;
        node)         (cd node-express && NODE_ENV=production exec "${SERVER_PREFIX[@]}" "$NODE_BIN" index.js) >"$log" 2>&1 & ;;
        node-cluster) (cd node-express && WORKERS="$WORKERS" NODE_ENV=production exec "${SERVER_PREFIX[@]}" "$NODE_BIN" cluster.js) >"$log" 2>&1 & ;;
        dotnet)       (cd dotnet-10 && ASPNETCORE_ENVIRONMENT=Production DOTNET_CLI_TELEMETRY_OPTOUT=1 \
                          exec "${SERVER_PREFIX[@]}" dotnet bin/Release/net10.0/dotnet-10.dll) >"$log" 2>&1 & ;;
        python)       (cd python-fastapi && exec "${SERVER_PREFIX[@]}" .venv/bin/uvicorn app:app --host 0.0.0.0 --port 3003 \
                          --workers "$WORKERS" --no-access-log --no-server-header --log-level warning) >"$log" 2>&1 & ;;
        rust)         (cd rust-axum && exec "${SERVER_PREFIX[@]}" ./target/release/rust-axum) >"$log" 2>&1 & ;;
    esac
    SERVER_PID=$!
    disown "$SERVER_PID"  # no "Terminated" job messages when it stops
}

stop_server() {
    [[ -z "$SERVER_PID" ]] && return 0
    # The server leads its own process group (see set -m above).
    kill -TERM -- "-$SERVER_PID" 2>/dev/null || kill -TERM "$SERVER_PID" 2>/dev/null || true
    for _ in $(seq 1 50); do
        kill -0 "$SERVER_PID" 2>/dev/null || break
        sleep 0.1
    done
    kill -KILL -- "-$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
}
trap stop_server EXIT
trap 'echo; echo "Interrupted"; exit 130' INT TERM

port_answers() {
    curl -s -o /dev/null -m 1 "http://localhost:$1/"
}

wait_for_port() {  # wait_for_port <port> <target>
    for _ in $(seq 1 100); do
        port_answers "$1" && return 0
        if ! kill -0 "$SERVER_PID" 2>/dev/null; then
            echo "!!! $2 exited before answering on port $1. Log: results/logs/$2.log" >&2
            tail -n 20 "results/logs/$2.log" >&2
            return 1
        fi
        sleep 0.2
    done
    echo "!!! $2 did not answer on port $1 within 20s. Log: results/logs/$2.log" >&2
    return 1
}

version_of() {  # prints "<framework> <version>|<runtime> <version>" for a target
    case "$1" in
        go) echo "net/http|Go $(go env GOVERSION | sed 's/^go//')" ;;
        node|node-cluster)
            local express; express="$("$NODE_BIN" -p "require('./node-express/node_modules/express/package.json').version")"
            local fw="Express $express"; [[ "$1" == node-cluster ]] && fw="Express $express cluster"
            echo "$fw|Node $("$NODE_BIN" -v | sed 's/^v//')" ;;
        dotnet)
            echo "minimal API|.NET $(dotnet --list-runtimes | awk '/^Microsoft.AspNetCore.App 10\./{v=$2} END{print v}')" ;;
        python)
            python-fastapi/.venv/bin/python -c 'import platform, fastapi; print(f"FastAPI {fastapi.__version__}|Python {platform.python_version()}")' ;;
        rust)
            local axum; axum="$(awk '/^name = "axum"$/{getline; gsub(/[^0-9.]/, ""); print; exit}' rust-axum/Cargo.lock)"
            echo "axum $axum|Rust $(rustc --version | awk '{print $2}')" ;;
    esac
}

record_info() {  # record_info <target>
    local v; v="$(version_of "$1")"
    mkdir -p results/info
    cat > "results/info/$1-$SCENARIO.json" <<JSON
{
  "target": "$1",
  "scenario": "$SCENARIO",
  "date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "framework": "${v%%|*}",
  "runtime": "${v#*|}",
  "k6": "$(k6 version | awk '{print $2}' | sed 's/^v//')",
  "cpu": "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)",
  "threads": $(nproc),
  "workers": $WORKERS,
  "server_cpus": "${SERVER_CPUS:-}",
  "k6_cpus": "${K6_CPUS:-}"
}
JSON
}

run_k6() {  # run_k6 <target> <extra k6 args...>
    local target="$1"; shift
    pin "${K6_CPUS:-}" k6 run -e TARGET="$target" -e SCENARIO="$SCENARIO" "$@" k6/smackdown.js
}

for target in $TARGETS; do
    port="$(port_of "$target")"
    echo "=== $target (port $port)"

    if port_answers "$port"; then
        echo "!!! Something is already listening on port $port. Stop it and try again." >&2
        exit 1
    fi

    build "$target"
    start_server "$target"
    wait_for_port "$port" "$target"
    echo "--- $target is up (pid $SERVER_PID)"

    if [[ "$CHECK_ONLY" == 1 ]]; then
        echo "--- response: $(curl -s "http://localhost:$port/")"
        curl -s -D - -o /dev/null "http://localhost:$port/" | tr -d "\r" | sed "/^$/d; s/^/    /"
    else
        rm -f results/"${target}-${SCENARIO}"-*.json  # drop older runs of this target
        record_info "$target"
        echo "--- warm-up run (not saved)"
        run_k6 "$target" --quiet --summary-mode=disabled
        for run in $(seq 1 "$RUNS"); do
            echo "--- run $run/$RUNS ($SCENARIO)"
            run_k6 "$target" --summary-export "results/${target}-${SCENARIO}-${run}.json"
        done
    fi

    stop_server
    if port_answers "$port"; then
        echo "!!! Port $port still answers after stopping $target." >&2
        exit 1
    fi
    echo "--- $target stopped"
done

if [[ "$CHECK_ONLY" == 0 ]]; then
    node k6/chart.js --scenario "$SCENARIO" ${CHART_NOTES:+--notes "$CHART_NOTES"}
fi
echo "=== done"
