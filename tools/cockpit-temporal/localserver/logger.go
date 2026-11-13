package localserver

import (
	"go.temporal.io/server/common/log"
	"go.temporal.io/server/common/log/tag"
)

// Temporal may log payloads or credentials. Suppress ordinary messages, but do not let a fatal
// condition continue silently; the helper process is isolated from the app.
type quietLogger struct{}

func (quietLogger) Debug(string, ...tag.Tag)   {}
func (quietLogger) Info(string, ...tag.Tag)    {}
func (quietLogger) Warn(string, ...tag.Tag)    {}
func (quietLogger) Error(string, ...tag.Tag)   {}
func (quietLogger) DPanic(string, ...tag.Tag)  {}
func (quietLogger) Panic(string, ...tag.Tag)   { panic("local Temporal encountered a fatal error") }
func (quietLogger) Fatal(string, ...tag.Tag)   { panic("local Temporal encountered a fatal error") }
func (quietLogger) With(...tag.Tag) log.Logger { return quietLogger{} }
