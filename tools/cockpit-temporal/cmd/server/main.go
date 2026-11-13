package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/t-boris/MarkView/cockpit-temporal/localserver"
)

func main() {
	runtime := flag.String("runtime", "", "private per-launch directory")
	state := flag.String("state", "", "private persistent directory")
	postgres := flag.String("postgres", "", "packaged PostgreSQL directory")
	supervisor := flag.String("supervisor", "", "packaged PostgreSQL supervisor")
	flag.Parse()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); cancel() }()
	server, err := localserver.Start(ctx, localserver.Options{Runtime: *runtime, State: *state, PostgresBinaries: *postgres, PostgresSupervisor: *supervisor})
	if err != nil {
		fmt.Fprintln(os.Stderr, "Local Temporal could not start; check its packaged dependencies and private storage.")
		os.Exit(1)
	}
	defer server.Close()
	if err := json.NewEncoder(os.Stdout).Encode(server.Endpoint); err != nil {
		return
	}
	<-ctx.Done()
}
