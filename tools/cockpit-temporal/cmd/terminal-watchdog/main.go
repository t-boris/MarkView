// terminal-watchdog holds the PTY master while MarkView is alive. On app death
// its stdin closes; it stops the foreground and shell process groups.
package main

import (
	"flag"
	"fmt"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

func main() {
	shell := flag.Int("shell-pid", 0, "PTY session leader")
	flag.Parse()
	if *shell <= 1 {
		os.Exit(2)
	}
	// fd 2 is the duplicated PTY master, not a logging stream.
	if _, err := unix.IoctlGetTermios(2, unix.TIOCGETA); err != nil {
		os.Exit(1)
	}
	if _, err := unix.IoctlGetInt(2, unix.TIOCGPGRP); err != nil {
		os.Exit(1)
	}
	fmt.Println(`{"ready":true}`)
	_, _ = io.Copy(io.Discard, os.Stdin)
	foreground, err := unix.IoctlGetInt(2, unix.TIOCGPGRP)
	if err != nil || foreground <= 1 || foreground == unix.Getpgrp() {
		return
	}
	// The PTY itself identifies its foreground group, even if its leader exited.
	_ = unix.Kill(-foreground, unix.SIGKILL)
	if sid, err := unix.Getsid(*shell); err == nil && sid == *shell {
		_ = unix.Kill(-*shell, unix.SIGKILL)
		_ = unix.Kill(*shell, unix.SIGKILL)
	}
}
