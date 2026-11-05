// Fastify, one worker per CPU core. Fastify compiles its routing and
// serialisation up front, so far less work happens per request than in Express.
const cluster = require('node:cluster')
const { availableParallelism } = require('node:os')

const port = 3007

if (cluster.isPrimary) {
    const workers = Number(process.env.WORKERS) || availableParallelism()
    for (let i = 0; i < workers; i++) cluster.fork()
} else {
    const fastify = require('fastify')({ logger: false })

    fastify.get('/', (request, reply) => {
        reply.header('content-type', 'text/plain; charset=utf-8').send('Fastify greets the world!')
    })

    fastify.listen({ port, host: '0.0.0.0' }).then(() => {
        console.log(`Fastify (pid ${process.pid}) listening at http://localhost:${port}`)
    })
}
