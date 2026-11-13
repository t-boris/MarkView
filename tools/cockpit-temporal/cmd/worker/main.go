package main

import (
	"flag"
	"fmt"
	"io"
	"net"
	"os"

	cockpit "github.com/t-boris/MarkView/cockpit-temporal"
	"go.temporal.io/sdk/activity"
	"go.temporal.io/sdk/client"
	"go.temporal.io/sdk/worker"
)

func main() {
	address := flag.String("address", "127.0.0.1:7233", "local Temporal address")
	queue := flag.String("queue", "", "task queue for this app instance")
	socket := flag.String("socket", "", "private MarkView host socket")
	flag.Parse()
	host, _, err := net.SplitHostPort(*address)
	if err != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() || *queue == "" || *socket == "" {
		fmt.Fprintln(os.Stderr, "a loopback address, task queue and host socket are required")
		os.Exit(2)
	}
	temporalClient, err := client.Dial(client.Options{HostPort: *address})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer temporalClient.Close()
	w := worker.New(temporalClient, *queue, worker.Options{})
	w.RegisterWorkflow(cockpit.Execute)
	hostActivity := cockpit.HostActivity{Socket: *socket}
	w.RegisterActivityWithOptions(hostActivity.RunStep, activity.RegisterOptions{Name: "cockpit.run-step"})
	if err := w.Start(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	// The app owns the write end of stdin; EOF shuts the worker down when the app exits or crashes.
	_, _ = io.Copy(io.Discard, os.Stdin)
	w.Stop()
}
