// Go on fasthttp, the engine under Fiber: it reuses request and response
// objects instead of allocating them, at the cost of not being net/http.
package main

import (
	"log"

	"github.com/valyala/fasthttp"
)

var body = []byte("GoFast  greets the world!")

func handler(ctx *fasthttp.RequestCtx) {
	if !ctx.IsGet() || string(ctx.Path()) != "/" {
		ctx.SetStatusCode(fasthttp.StatusNotFound)
		return
	}
	ctx.SetContentType("text/plain; charset=utf-8")
	ctx.SetBody(body)
}

func main() {
	server := &fasthttp.Server{
		Handler:               handler,
		Name:                  "",
		NoDefaultServerHeader: true,
	}
	log.Println("Go (fasthttp) listening at http://localhost:3006")
	log.Fatal(server.ListenAndServe(":3006"))
}
