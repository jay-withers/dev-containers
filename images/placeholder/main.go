// The placeholder app: answers 200 on every path, on $PORT.
//
// An app's Terraform creates its container app with this image before the
// app's first release exists, so the first apply succeeds and the app's own
// pipeline deploys the real image over it. Every path answers 200 because the
// app's probes point at the app's own health path (/healthz, /api/health),
// which this server cannot know.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"time"
)

const body = "Placeholder: this app's first release has not been deployed yet.\n"

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	server := &http.Server{
		Addr: ":" + port,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			fmt.Fprint(w, body)
		}),
		ReadHeaderTimeout: 5 * time.Second,
	}

	log.Printf("placeholder listening on :%s", port)
	log.Fatal(server.ListenAndServe())
}
