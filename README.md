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
npm init
npm install express --save
```

### k6 (Load testing)

Follow [the setup on the k6 website](https://k6.io/docs/getting-started/installation/).
