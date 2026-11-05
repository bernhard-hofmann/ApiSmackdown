package main

import (
	"log"
	"net/http"
)

func main() {
	http.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte("Golang  greets the world!"))
	})

	log.Println("Go (net/http) listening at http://localhost:3000")
	log.Fatal(http.ListenAndServe(":3000", nil))
}
