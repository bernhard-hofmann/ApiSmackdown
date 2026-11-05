#!/usr/bin/env bash
# Builds, starts, benchmarks and stops each server in turn, so only one
# server runs at a time.
#
#   k6/run-all.sh             # run the benchmark
#   k6/run-all.sh --check     # start each server, show its response and headers, stop it
#
# Environment (all optional):
#   TARGETS      servers to test, in order. Group names expand:
#                  idiomatic = go node node-cluster dotnet python rust
#                  tuned     = go-fasthttp node-fastify dotnet-tuned python-granian rust-tuned rust-epoll
#                  all       = idiomatic + tuned (the default)
#   SCENARIO     steady (default, k6 10 VUs), ramp (k6 10 -> 100 VUs),
#                or oha (oha, OHA_CONNECTIONS connections: the heavy test)
#   RUNS         saved runs per server after one warm-up run (default: 3)
#   OHA_CONNECTIONS  connections for the oha scenario (default: 256)
#   OHA_DURATION     length of each oha run (default: 30s)
#   NODE_BIN     node binary (default: /opt/node-26/bin/node if present, else node)
#   WORKERS      worker processes/threads for the multi-process servers (default: one per core)
#   SERVER_CPUS  pin servers to these cores, e.g. 0-7 (uses taskset)
#   LOAD_CPUS    pin the load generator (k6 or oha) to these cores, e.g. 8-15
#                (K6_CPUS is accepted as an older name)
#
# Each run's summary goes to results/<target>-<scenario>-<n>.json, the
# versions and machine details to results/info/<target>-<scenario>.json, and
# server output to results/logs/<target>.log. At the end, k6/chart.js draws a
# timestamped chart in results/charts/ from every result saved for that
# scenario and points the README at it (set CHART_NOTES to a text file to add
# your own notes to the chart).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

IDIOMATIC="go node node-cluster dotnet python rust"
TUNED="go-fasthttp node-fastify dotnet-tuned python-granian rust-tuned rust-epoll"
expand_targets() {
    local out=() t
    for t in $1; do
        case "$t" in
            idiomatic) out+=($IDIOMATIC) ;;
            tuned) out+=($TUNED) ;;
            all) out+=($IDIOMATIC $TUNED) ;;
            *) out+=("$t") ;;
        esac
    done
    echo "${out[*]}"
}
TARGETS="$(expand_targets "${TARGETS:-all}")"

WORKERS="${WORKERS:-$(nproc)}"
SCENARIO="${SCENARIO:-steady}"
RUNS="${RUNS:-3}"
OHA_CONNECTIONS="${OHA_CONNECTIONS:-256}"
OHA_DURATION="${OHA_DURATION:-30s}"
LOAD_CPUS="${LOAD_CPUS:-${K6_CPUS:-}}"
if [[ -z "${NODE_BIN:-}" ]]; then
    if [[ -x /opt/node-26/bin/node ]]; then NODE_BIN=/opt/node-26/bin/node; else NODE_BIN=node; fi
fi

case "$SCENARIO" in
    steady|ramp) LOADGEN=k6 ;;
    oha) LOADGEN=oha ;;
    *) echo "Unknown SCENARIO: $SCENARIO (use steady, ramp or oha)" >&2; exit 1 ;;
esac
if [[ "$CHECK_ONLY" == 0 ]] && ! command -v "$LOADGEN" >/dev/null; then
    echo "!!! $LOADGEN is not installed (needed for SCENARIO=$SCENARIO)." >&2
    exit 1
fi

mkdir -p results/logs

port_of() {
    case "$1" in
        go) echo 3000 ;;
        node|node-cluster) echo 3001 ;;
        dotnet) echo 3002 ;;
        python) echo 3003 ;;
        rust) echo 3004 ;;
        rust-tuned) echo 3005 ;;
        go-fasthttp) echo 3006 ;;
        node-fastify) echo 3007 ;;
        python-granian) echo 3008 ;;
        dotnet-tuned) echo 3009 ;;
        rust-epoll) echo 3010 ;;
        *) echo "Unknown target: $1" >&2; exit 1 ;;
    esac
}

pin() {  # pin <cpus> <command...>
    local cpus="$1"; shift
    if [[ -n "$cpus" ]]; then taskset -c "$cpus" "$@"; else "$@"; fi
}

dotnet_build() {  # dotnet_build <folder>
    (cd "$1" && DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet build -c Release -v quiet -nologo)
}

npm_install() {  # npm_install <folder>
    if [[ ! -d "$1/node_modules" ]]; then
        echo "--- installing Node dependencies"
        (cd "$1" && PATH="$(dirname "$NODE_BIN"):$PATH" npm ci --no-fund --no-audit)
    fi
}

build() {
    echo "--- building $1"
    case "$1" in
        go)             (cd go-stdlib && go build -o server .) ;;
        go-fasthttp)    (cd go-fasthttp && go build -o server .) ;;
        node|node-cluster) npm_install node-express ;;
        node-fastify)   npm_install node-fastify ;;
        dotnet)         dotnet_build dotnet-10 ;;
        dotnet-tuned)   dotnet_build dotnet-10-tuned ;;
        python)         (cd python-fastapi && uv sync --frozen --quiet) ;;
        python-granian) (cd python-granian && uv sync --frozen --quiet) ;;
        rust)           (cd rust-axum && cargo build --release --quiet) ;;
        # Same code as "rust"; optimised for this exact CPU, so build it on the benchmark machine.
        rust-tuned)     (cd rust-axum && RUSTFLAGS="-C target-cpu=native" \
                            cargo build --profile tuned --features mimalloc --quiet) ;;
        rust-epoll)     (cd rust-epoll && RUSTFLAGS="-C target-cpu=native" cargo build --release --quiet) ;;
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
        go-fasthttp)  (cd go-fasthttp && exec "${SERVER_PREFIX[@]}" ./server) >"$log" 2>&1 & ;;
        node)         (cd node-express && NODE_ENV=production exec "${SERVER_PREFIX[@]}" "$NODE_BIN" index.js) >"$log" 2>&1 & ;;
        node-cluster) (cd node-express && WORKERS="$WORKERS" NODE_ENV=production exec "${SERVER_PREFIX[@]}" "$NODE_BIN" cluster.js) >"$log" 2>&1 & ;;
        node-fastify) (cd node-fastify && WORKERS="$WORKERS" NODE_ENV=production exec "${SERVER_PREFIX[@]}" "$NODE_BIN" server.js) >"$log" 2>&1 & ;;
        dotnet)       (cd dotnet-10 && ASPNETCORE_ENVIRONMENT=Production DOTNET_CLI_TELEMETRY_OPTOUT=1 \
                          exec "${SERVER_PREFIX[@]}" dotnet bin/Release/net10.0/dotnet-10.dll) >"$log" 2>&1 & ;;
        dotnet-tuned) (cd dotnet-10-tuned && ASPNETCORE_ENVIRONMENT=Production DOTNET_CLI_TELEMETRY_OPTOUT=1 \
                          exec "${SERVER_PREFIX[@]}" dotnet bin/Release/net10.0/dotnet-10-tuned.dll) >"$log" 2>&1 & ;;
        python)       (cd python-fastapi && exec "${SERVER_PREFIX[@]}" .venv/bin/uvicorn app:app --host 0.0.0.0 --port 3003 \
                          --workers "$WORKERS" --no-access-log --no-server-header --log-level warning) >"$log" 2>&1 & ;;
        python-granian) (cd python-granian && exec "${SERVER_PREFIX[@]}" .venv/bin/granian app:app --interface rsgi \
                          --host 0.0.0.0 --port 3008 --workers "$WORKERS" --runtime-mode st --http 1 --no-ws \
                          --loop uvloop --no-access-log --log-level warning) >"$log" 2>&1 & ;;
        rust)         (cd rust-axum && exec "${SERVER_PREFIX[@]}" ./target/release/rust-axum) >"$log" 2>&1 & ;;
        rust-tuned)   (cd rust-axum && PORT=3005 exec "${SERVER_PREFIX[@]}" ./target/tuned/rust-axum) >"$log" 2>&1 & ;;
        rust-epoll)   (cd rust-epoll && WORKERS="$WORKERS" exec "${SERVER_PREFIX[@]}" ./target/release/rust-epoll) >"$log" 2>&1 & ;;
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
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$1/"
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

lock_version() {  # lock_version <Cargo.lock> <crate>
    awk -v name="name = \"$2\"" '$0 == name {getline; gsub(/[^0-9.]/, ""); print; exit}' "$1"
}

version_of() {  # prints "<framework and version>|<runtime and version>" for a target
    local go node dotnet python rust
    case "$1" in
        go|go-fasthttp) go="Go $(go env GOVERSION | sed 's/^go//')" ;;
        node*) node="Node $("$NODE_BIN" -v | sed 's/^v//')" ;;
        dotnet*) dotnet=".NET $(dotnet --list-runtimes | awk '/^Microsoft.AspNetCore.App 10\./{v=$2} END{print v}')" ;;
        rust*) rust="Rust $(rustc --version | awk '{print $2}')" ;;
    esac
    case "$1" in
        go) echo "net/http|$go" ;;
        go-fasthttp) echo "fasthttp $(awk '/valyala\/fasthttp /{for (i = 1; i <= NF; i++) if ($i ~ /^v[0-9]/) print substr($i, 2)}' go-fasthttp/go.mod)|$go" ;;
        node|node-cluster)
            local express; express="$("$NODE_BIN" -p "require('./node-express/node_modules/express/package.json').version")"
            local fw="Express $express"; [[ "$1" == node-cluster ]] && fw="Express $express cluster"
            echo "$fw|$node" ;;
        node-fastify)
            echo "Fastify $("$NODE_BIN" -p "require('./node-fastify/node_modules/fastify/package.json').version") cluster|$node" ;;
        dotnet) echo "minimal API|$dotnet" ;;
        dotnet-tuned) echo "bare handler|$dotnet" ;;
        python)
            python-fastapi/.venv/bin/python -c 'import platform, fastapi; print(f"FastAPI {fastapi.__version__}|Python {platform.python_version()}")' ;;
        python-granian)
            python-granian/.venv/bin/python -c 'import platform, importlib.metadata as m; v = m.version("granian"); print(f"Granian {v} (RSGI)|Python {platform.python_version()}")' ;;
        rust) echo "axum $(lock_version rust-axum/Cargo.lock axum)|$rust" ;;
        rust-tuned) echo "axum $(lock_version rust-axum/Cargo.lock axum), tuned build|$rust" ;;
        rust-epoll) echo "no framework|$rust" ;;
    esac
}

load_description() {
    case "$SCENARIO" in
        steady) echo "k6 $(k6 version | awk '{print $2}' | sed 's/^v//'), 10 virtual users for 30 s" ;;
        ramp) echo "k6 $(k6 version | awk '{print $2}' | sed 's/^v//'), 10 → 100 virtual users over 1 min, then 30 s at 100" ;;
        oha) echo "oha $(oha --version | awk '{print $2}'), $OHA_CONNECTIONS connections for $OHA_DURATION" ;;
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
  "load": "$(load_description)",
  "cpu": "$(awk -F': ' '/^model name/{print $2; exit}' /proc/cpuinfo)",
  "threads": $(nproc),
  "workers": $WORKERS,
  "server_cpus": "${SERVER_CPUS:-}",
  "load_cpus": "$LOAD_CPUS"
}
JSON
}

run_k6() {  # run_k6 <target> <extra k6 args...>
    local target="$1"; shift
    pin "$LOAD_CPUS" k6 run -e TARGET="$target" -e SCENARIO="$SCENARIO" "$@" k6/smackdown.js
}

run_oha() {  # run_oha <port> <duration> <output file>
    pin "$LOAD_CPUS" oha -z "$2" -c "$OHA_CONNECTIONS" --no-tui --output-format json "http://127.0.0.1:$1/" > "$3"
    # oha doesn't check responses, so check its summary: every request must
    # have succeeded with a 200 and a 25-byte body.
    node -e '
        const j = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"));
        const codes = Object.keys(j.statusCodeDistribution || {});
        const errors = Object.keys(j.errorDistribution || {});
        const ok = j.summary.successRate === 1 && codes.length === 1 && codes[0] === "200"
            && errors.length === 0 && j.summary.sizePerRequest === 25;
        console.log(`    ${Math.round(j.summary.requestsPerSec).toLocaleString("en-US")} req/s, ` +
            `p95 ${(j.latencyPercentiles.p95 * 1e6).toFixed(0)} µs, status ${JSON.stringify(j.statusCodeDistribution)}` +
            (errors.length ? `, errors ${JSON.stringify(j.errorDistribution)}` : ""));
        if (!ok) { console.error("!!! Some requests failed or returned the wrong response."); process.exit(1); }
    ' "$3"
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
        echo "--- response: $(curl -s "http://127.0.0.1:$port/")"
        curl -s -D - -o /dev/null "http://127.0.0.1:$port/" | tr -d "\r" | sed "/^$/d; s/^/    /"
    else
        rm -f results/"${target}-${SCENARIO}"-*.json  # drop older runs of this target
        record_info "$target"
        echo "--- warm-up run (not saved)"
        if [[ "$LOADGEN" == oha ]]; then
            run_oha "$port" 10s "results/logs/${target}-warmup.json" >/dev/null
        else
            run_k6 "$target" --quiet --summary-mode=disabled
        fi
        for run in $(seq 1 "$RUNS"); do
            echo "--- run $run/$RUNS ($SCENARIO)"
            out="results/${target}-${SCENARIO}-${run}.json"
            if [[ "$LOADGEN" == oha ]]; then
                run_oha "$port" "$OHA_DURATION" "$out"
            else
                run_k6 "$target" --summary-export "$out"
            fi
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
