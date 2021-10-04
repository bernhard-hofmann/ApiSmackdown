# ApiSmackdown

This repo is intended to allow comparison of the performance and simplicity (maintenance costs) of various API backend languages and frameworks.

## Setups

### Go (Fiber)

Setup modules and get the fiber module:

```bash
cd go-fiber
go mod init github.com/bernhard-hofmann/ApiSmackdown
go get github.com/gofiber/fiber
go run main.go
```

### Node (Express)

```bash
cd node-express
npm init
npm install express --save
```

### k6 (Load testing)

Follow [the setup on the k6 website](https://k6.io/docs/getting-started/installation/).

## Results

To save the reader time, I'll publish results here. Note, these are from my laptop and are, as such, completely non-scientific. They may offer the reader some insight because the tests will be run one after the other at the same time on the same hardware.

```
$ k6 run go-fiber.js

          /\      |‾‾| /‾‾/   /‾‾/
     /\  /  \     |  |/  /   /  /
    /  \/    \    |     (   /   ‾‾\
   /          \   |  |\  \ |  (‾)  |
  / __________ \  |__| \__\ \_____/ .io

  execution: local
     script: go-fiber.js
     output: -

  scenarios: (100.00%) 1 scenario, 10 max VUs, 1m0s max duration (incl. graceful stop):
           * default: 10 looping VUs for 30s (gracefulStop: 30s)


running (0m30.0s), 00/10 VUs, 300 complete and 0 interrupted iterations
default ✓ [======================================] 10 VUs  30s

     data_received..................: 43 kB 1.4 kB/s
     data_sent......................: 24 kB 799 B/s
     http_req_blocked...............: avg=12.41µs  min=3.73µs   med=8.24µs   max=153.28µs p(90)=11.01µs  p(95)=13.11µs
     http_req_connecting............: avg=3.08µs   min=0s       med=0s       max=115.27µs p(90)=0s       p(95)=0s
     http_req_duration..............: avg=449.57µs min=186.68µs med=444.21µs max=943.07µs p(90)=604.6µs  p(95)=660.59µs
       { expected_response:true }...: avg=449.57µs min=186.68µs med=444.21µs max=943.07µs p(90)=604.6µs  p(95)=660.59µs
     http_req_failed................: 0.00% ✓ 0        ✗ 300
     http_req_receiving.............: avg=86.53µs  min=19.98µs  med=87.51µs  max=180.8µs  p(90)=107.95µs p(95)=117.73µs
     http_req_sending...............: avg=39.68µs  min=18.87µs  med=35.46µs  max=311.38µs p(90)=44.16µs  p(95)=50.94µs
     http_req_tls_handshaking.......: avg=0s       min=0s       med=0s       max=0s       p(90)=0s       p(95)=0s
     http_req_waiting...............: avg=323.35µs min=112.44µs med=314.58µs max=689.05µs p(90)=455.2µs  p(95)=512.46µs
     http_reqs......................: 300   9.984912/s
     iteration_duration.............: avg=1s       min=1s       med=1s       max=1s       p(90)=1s       p(95)=1s
     iterations.....................: 300   9.984912/s
     vus............................: 10    min=10     max=10
     vus_max........................: 10    min=10     max=10

$ k6 run node-express.js

          /\      |‾‾| /‾‾/   /‾‾/
     /\  /  \     |  |/  /   /  /
    /  \/    \    |     (   /   ‾‾\
   /          \   |  |\  \ |  (‾)  |
  / __________ \  |__| \__\ \_____/ .io

  execution: local
     script: node-express.js
     output: -

  scenarios: (100.00%) 1 scenario, 10 max VUs, 1m0s max duration (incl. graceful stop):
           * default: 10 looping VUs for 30s (gracefulStop: 30s)


running (0m30.1s), 00/10 VUs, 300 complete and 0 interrupted iterations
default ✓ [======================================] 10 VUs  30s

     data_received..................: 69 kB 2.3 kB/s
     data_sent......................: 24 kB 798 B/s
     http_req_blocked...............: avg=13.26µs min=1.06µs   med=7.26µs  max=779.1µs  p(90)=9.92µs   p(95)=13.01µs
     http_req_connecting............: avg=4.94µs  min=0s       med=0s      max=754.41µs p(90)=0s       p(95)=0s
     http_req_duration..............: avg=1.89ms  min=223.27µs med=1.65ms  max=7.27ms   p(90)=3.26ms   p(95)=4.51ms
       { expected_response:true }...: avg=1.89ms  min=223.27µs med=1.65ms  max=7.27ms   p(90)=3.26ms   p(95)=4.51ms
     http_req_failed................: 0.00% ✓ 0        ✗ 300
     http_req_receiving.............: avg=82.62µs min=10.98µs  med=89.79µs max=316.55µs p(90)=137.49µs p(95)=182.18µs
     http_req_sending...............: avg=36.61µs min=4.7µs    med=32.57µs max=304.35µs p(90)=46.43µs  p(95)=53.62µs
     http_req_tls_handshaking.......: avg=0s      min=0s       med=0s      max=0s       p(90)=0s       p(95)=0s
     http_req_waiting...............: avg=1.77ms  min=203.22µs med=1.57ms  max=7.12ms   p(90)=3.2ms    p(95)=4.38ms
     http_reqs......................: 300   9.973763/s
     iteration_duration.............: avg=1s      min=1s       med=1s      max=1s       p(90)=1s       p(95)=1s
     iterations.....................: 300   9.973763/s
     vus............................: 10    min=10     max=10
     vus_max........................: 10    min=10     max=10
```
