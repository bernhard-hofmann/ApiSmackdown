// Runs one Express worker per CPU core so Node uses the whole machine,
// like the Go and .NET servers do. The workers share port 3001.
const cluster = require('node:cluster')
const { availableParallelism } = require('node:os')

if (cluster.isPrimary) {
    const workers = Number(process.env.WORKERS) || availableParallelism()
    for (let i = 0; i < workers; i++) cluster.fork()
} else {
    require('./index.js')
}
