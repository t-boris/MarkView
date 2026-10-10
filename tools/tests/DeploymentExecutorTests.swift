import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

let local = LocalExecutor(directory: nil)
let hello = await local.run("echo hello; echo oops 1>&2", stdin: nil, timeout: 10)
check(hello.succeeded && hello.stdout == "hello\n" && hello.stderr == "oops\n", "stdout and stderr are kept apart")
let failing = await local.run("exit 3", stdin: nil, timeout: 10)
check(failing.status == 3 && !failing.succeeded, "the exit status is kept")
let cat = await local.run("cat", stdin: "from stdin\n", timeout: 10)
check(cat.stdout == "from stdin\n", "stdin reaches the command")
let started = Date()
let slow = await local.run("sleep 20", stdin: nil, timeout: 1)
check(slow.timedOut && Date().timeIntervalSince(started) < 8, "a slow command is stopped at the timeout (\(Date().timeIntervalSince(started)) s)")
let big = await local.run("head -c 3000000 /dev/zero | tr '\\0' 'a'", stdin: nil, timeout: 20)
check(big.truncated && big.stdout.utf8.count == ProcessRunner.outputCap, "output is cut at the cap")
let both = await local.run("yes x | head -n 300000 1>&2; echo done", stdin: nil, timeout: 20)
check(both.stdout == "done\n", "a noisy stderr cannot stall the command")
let path = await local.run("command -v ls", stdin: nil, timeout: 10)
check(path.succeeded, "the PATH of a shell is set")

// The ssh command line.
var env = DeploymentEnvironment(id: "prod", name: "Prod", kind: .ssh, host: "web-1.example.com", user: "deploy", port: 2222)
let args = SSHExecutor.arguments(for: env) ?? []
check(args.contains("BatchMode=yes") && args.contains("2222") && args.last == "deploy@web-1.example.com", "ssh: batch mode, port, destination last: \(args)")
check(!args.contains("-i"), "ssh: no key option without a key file")
env.identityFile = "~/.ssh/prod"
let withKey = SSHExecutor.arguments(for: env) ?? []
check(withKey.contains("-i") && withKey.contains(NSHomeDirectory() + "/.ssh/prod") && withKey.contains("IdentitiesOnly=yes"), "ssh: the key file is expanded and the only one used")
env.host = "-oProxyCommand=touch /tmp/pwned"
check(SSHExecutor.arguments(for: env) == nil, "ssh: a host that looks like an option is refused")
let refused = await SSHExecutor(environment: env).run("uptime", stdin: nil, timeout: 5)
check(refused.status == 255 && refused.stderr.contains("not valid"), "and nothing runs")

// What ssh said.
func result(_ text: String, status: Int32 = 255) -> CommandResult { CommandResult(status: status, stdout: "", stderr: text) }
check(ConnectionProblem.from(result("Host key verification failed.")) == .hostKeyUnknown, "unknown host key")
check(ConnectionProblem.from(result("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@")) == .hostKeyChanged, "changed host key")
check(ConnectionProblem.from(result("deploy@h: Permission denied (publickey).")) == .authFailed, "refused key")
if case .unreachable(let line)? = ConnectionProblem.from(result("ssh: connect to host h port 22: Connection refused")) { check(line.contains("refused"), "refused connection") } else { check(false, "refused connection") }
check(ConnectionProblem.from(CommandResult(status: -1, stdout: "", stderr: "", timedOut: true)) == .timedOut, "timeout")
check(ConnectionProblem.from(CommandResult(status: 1, stdout: "", stderr: "grep: no match")) == nil, "a failing remote command is not a connection problem")
check(ConnectionProblem.from(CommandResult(status: 0, stdout: "x", stderr: "")) == nil, "success is not a problem")
check(ConnectionProblem.hostKeyChanged.message.contains("will not continue"), "a changed key is never trusted")
check(await HostKeys.scan(host: "-oProxyCommand=x", port: 22) == nil, "host key scan refuses an unsafe host")

print(failures == 0 ? "All deployment executor checks passed." : "\(failures) deployment executor check(s) failed.")
exit(failures == 0 ? 0 : 1)
