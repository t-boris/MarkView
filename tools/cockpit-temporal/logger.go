package cockpit

// Workflow payloads can contain project content. Diagnostics are returned as errors to MarkView,
// not written to a helper's stdout or a shared log.
type QuietSDKLogger struct{}

func (QuietSDKLogger) Debug(string, ...interface{}) {}
func (QuietSDKLogger) Info(string, ...interface{})  {}
func (QuietSDKLogger) Warn(string, ...interface{})  {}
func (QuietSDKLogger) Error(string, ...interface{}) {}
