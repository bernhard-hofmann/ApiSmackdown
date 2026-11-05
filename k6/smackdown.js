// One load test for every server.
//
//   k6 run -e TARGET=go k6/smackdown.js
//   k6 run -e TARGET=dotnet -e SCENARIO=ramp k6/smackdown.js
//
// TARGET:   any target name from k6/run-all.sh, e.g. go, rust-epoll (or set BASE_URL)
// SCENARIO: steady (default, same as the 2021 runs: 10 VUs for 30s)
//           ramp   (10 -> 100 VUs over 1m, then 30s at 100)
import http from 'k6/http';
import { check } from 'k6';

const TARGETS = {
    go: 'http://127.0.0.1:3000/',
    node: 'http://127.0.0.1:3001/',
    'node-cluster': 'http://127.0.0.1:3001/',
    dotnet: 'http://127.0.0.1:3002/',
    python: 'http://127.0.0.1:3003/',
    rust: 'http://127.0.0.1:3004/',
    'rust-tuned': 'http://127.0.0.1:3005/',
    'go-fasthttp': 'http://127.0.0.1:3006/',
    'node-fastify': 'http://127.0.0.1:3007/',
    'python-granian': 'http://127.0.0.1:3008/',
    'dotnet-tuned': 'http://127.0.0.1:3009/',
    'rust-epoll': 'http://127.0.0.1:3010/',
};

const target = __ENV.TARGET || 'go';
const url = __ENV.BASE_URL || TARGETS[target];
if (!url) {
    throw new Error(`Unknown TARGET "${target}". Use one of: ${Object.keys(TARGETS).join(', ')}, or set BASE_URL.`);
}

const SCENARIOS = {
    steady: {
        executor: 'constant-vus',
        vus: 10,
        duration: '30s',
    },
    ramp: {
        executor: 'ramping-vus',
        startVUs: 10,
        stages: [
            { duration: '1m', target: 100 },
            { duration: '30s', target: 100 },
        ],
    },
};

const scenario = __ENV.SCENARIO || 'steady';
if (!SCENARIOS[scenario]) {
    throw new Error(`Unknown SCENARIO "${scenario}". Use one of: ${Object.keys(SCENARIOS).join(', ')}.`);
}

export const options = {
    scenarios: { [scenario]: SCENARIOS[scenario] },
    thresholds: {
        http_req_failed: ['rate==0'],
        checks: ['rate==1'],
    },
};

export default function () {
    const res = http.get(url);
    check(res, {
        'status is 200': (r) => r.status === 200,
        'body is 25 bytes': (r) => r.body && r.body.length === 25,
    });
}
