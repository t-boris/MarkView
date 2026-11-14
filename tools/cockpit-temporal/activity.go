package cockpit

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"time"

	"go.temporal.io/sdk/activity"
)

// HostActivity is registered by the worker owned by the MarkView process. The socket is created by the app;
// one request represents one separately assigned agent session.
type HostActivity struct{ Socket string }

type hostReply struct {
	Result Result `json:"result"`
	Error  string `json:"error"`
}

func (host HostActivity) RunStep(ctx context.Context, task StepTask) (Result, error) {
	done := make(chan struct{})
	defer close(done)
	go func() {
		ticker := time.NewTicker(5 * time.Second)
		defer ticker.Stop()
		for {
			select {
			case <-done:
				return
			case <-ctx.Done():
				return
			case <-ticker.C:
				activity.RecordHeartbeat(ctx, task.Step.ID)
			}
		}
	}()
	return host.send(ctx, task)
}

func (host HostActivity) send(ctx context.Context, task StepTask) (Result, error) {
	if !filepath.IsAbs(host.Socket) {
		return Result{}, errors.New("host socket path must be absolute")
	}
	info, err := os.Lstat(host.Socket)
	if err != nil {
		return Result{}, err
	}
	if info.Mode()&os.ModeSocket == 0 || info.Mode().Perm()&0077 != 0 {
		return Result{}, errors.New("host socket must be private")
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", host.Socket)
	if err != nil {
		return Result{}, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := json.NewEncoder(conn).Encode(task); err != nil {
		return Result{}, err
	}
	var reply hostReply
	if err := json.NewDecoder(io.LimitReader(conn, 1<<20)).Decode(&reply); err != nil {
		return Result{}, err
	}
	if reply.Error != "" {
		return Result{}, fmt.Errorf("host: %s", reply.Error)
	}
	return reply.Result, nil
}
