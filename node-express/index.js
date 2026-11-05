const express = require('express')
const app = express()
const port = 3001

app.disable('x-powered-by')
app.disable('etag')

app.get('/', (req, res) => {
    res.type('text/plain').send('Express greets the world!')
})

app.listen(port, () => {
    console.log(`Express (pid ${process.pid}) listening at http://localhost:${port}`)
})
