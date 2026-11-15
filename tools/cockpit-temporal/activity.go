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
	"strings"
	"syscall"
	"time"

	"go.temporal.io/sdk/activity"
)

// HostActivity is registered by the worker owned by the MarkView process. The socket is created by the app;
// one request represents one separately assigned agent session.
type HostActivity struct{ Socket string }

// hostRequest is the task as the app reads it: the step's own fields with the host socket's token next to them.
type hostRequest struct {
	StepTask
	Token string `json:"token"`
}

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
	token, err := hostToken(host.Socket)
	if err != nil {
		return Result{}, err
	}
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", host.Socket)
	if err != nil {
		return Result{}, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	if err := json.NewEncoder(conn).Encode(hostRequest{StepTask: task, Token: token}); err != nil {
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

// hostToken reads the app's per-socket token from the private file next to the socket ("host.sock" -> "host.token"),
// the same convention as the app's PrivateSocket: the app serves only a caller that presents it. The file must be a
// regular file of this user that no one else can read; there is no other way to learn the token.
func hostToken(socket string) (string, error) {
	path := socket + ".token"
	if strings.HasSuffix(socket, ".sock") {
		path = strings.TrimSuffix(socket, ".sock") + ".token"
	}
	file, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", errors.New("host token unavailable")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return "", errors.New("host token unavailable")
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0 || !ok || int(owner.Uid) != os.Getuid() || info.Size() > 8192 {
		return "", errors.New("host token must be a private file of this user")
	}
	data, err := io.ReadAll(file)
	token := strings.TrimSpace(string(data))
	if err != nil || token == "" {
		return "", errors.New("host token unavailable")
	}
	return token, nil
}
