import Foundation

var failures = 0
func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message) (line \(line))") }
}

func sh(_ command: String) -> CommandResult { ProcessRunner.runBlocking(executable: "/bin/sh", arguments: ["-c", command], stdin: nil, timeout: 30, directory: nil, environment: nil) }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mv-ssh-\(UUID().uuidString.prefix(8))")
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { _ = sh("pkill -F '\(dir.path)/sshd.pid' 2>/dev/null; rm -rf '\(dir.path)'") }
let port = 22_000 + Int.random(in: 100..<900)
_ = sh("ssh-keygen -q -t ed25519 -N '' -f '\(dir.path)/host' && ssh-keygen -q -t ed25519 -N '' -f '\(dir.path)/user' && cp '\(dir.path)/user.pub' '\(dir.path)/authorized_keys' && chmod 600 '\(dir.path)/authorized_keys'")
let user = NSUserName()
try """
Port \(port)
ListenAddress 127.0.0.1
HostKey \(dir.path)/host
PidFile \(dir.path)/sshd.pid
AuthorizedKeysFile \(dir.path)/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
AllowUsers \(user)
LogLevel QUIET
""".write(to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
let server = Process()
server.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
server.arguments = ["-D", "-f", "\(dir.path)/sshd_config"]
server.standardError = FileHandle.nullDevice
server.standardOutput = FileHandle.nullDevice
try? server.run()
defer { if server.isRunning { server.terminate() } }
var up = false
for _ in 0..<40 { if sh("nc -z -w1 127.0.0.1 \(port)").succeeded { up = true; break }; try? await Task.sleep(nanoseconds: 250_000_000) }
func finish(_ code: Int32) -> Never {
    if server.isRunning { server.terminate() }
    _ = sh("rm -rf '\(dir.path)'")
    exit(code)
}
guard up else { print("skip: a private sshd could not start here"); finish(0) }

let known = dir.appendingPathComponent("known_hosts").path
var env = DeploymentEnvironment(id: "t", name: "T", kind: .ssh, host: "127.0.0.1", user: user, port: port, identityFile: "\(dir.path)/user")

// Without the host key the connection is refused, as in the app.
SSHExecutor.extraOptions = ["-o", "UserKnownHostsFile=\(known)", "-o", "GlobalKnownHostsFile=/dev/null"]
let unknown = await SSHExecutor(environment: env).run("echo hi", stdin: nil, timeout: 20)
check(ConnectionProblem.from(unknown) == .hostKeyUnknown, "an unknown host key is refused: \(unknown.stderr.prefix(100))")

// Trust it the way the app does: scan, show fingerprints, append.
let scanned = await HostKeys.scan(host: "127.0.0.1", port: port)
check(scanned != nil && !(scanned?.lines.isEmpty ?? true) && (scanned?.fingerprints.first?.contains("SHA256:") ?? false), "the host key is read with its fingerprint: \(scanned?.fingerprints.first ?? "-")")
try (scanned?.lines.joined(separator: "\n") ?? "").appending("\n").write(toFile: known, atomically: true, encoding: .utf8)

let hello = await SSHExecutor(environment: env).run("echo hello from the server", stdin: nil, timeout: 20)
check(hello.succeeded && hello.stdout == "hello from the server\n", "a command runs over ssh: \(hello.stderr)")
let policy = await SSHExecutor(environment: env).run("exit 7", stdin: nil, timeout: 20)
check(policy.status == 7 && ConnectionProblem.from(policy) == nil, "a failing remote command keeps its status and is not a connection problem")

// The probe over ssh, with checks.
let checks = [DeploymentCheck(id: "uname", title: "uname", kind: .command, target: "uname -s"),
              DeploymentCheck(id: "closed", title: "closed port", kind: .port, target: "127.0.0.1:1")]
let probe = await SSHExecutor(environment: env).run("sh -s", stdin: SystemProbe.script(checks: checks), timeout: 40)
let snapshot = SystemProbe.parse(probe.stdout)
check(probe.succeeded && !snapshot.os.isEmpty && snapshot.cpus > 0 && snapshot.memTotalKB > 0 && !snapshot.disks.isEmpty, "the probe script runs over ssh and parses: \(snapshot.os) \(snapshot.cpus) cpus, \(snapshot.disks.count) disks")
check(snapshot.checks.first { $0.id == "uname" }?.status == .ok && snapshot.checks.first { $0.id == "closed" }?.status == .fail, "checks run on the server")

// A key the server does not know.
_ = sh("ssh-keygen -q -t ed25519 -N '' -f '\(dir.path)/other'")
env.identityFile = "\(dir.path)/other"
let denied = await SSHExecutor(environment: env).run("echo hi", stdin: nil, timeout: 20)
check(ConnectionProblem.from(denied) == .authFailed, "a key the server refuses is reported: \(denied.stderr.prefix(80))")

// Nothing listening.
env.identityFile = "\(dir.path)/user"
env.port = port + 1
let refused = await SSHExecutor(environment: env).run("echo hi", stdin: nil, timeout: 20)
if case .unreachable? = ConnectionProblem.from(refused) { check(true, "a port with nothing behind it is unreachable") } else { check(false, "a port with nothing behind it is unreachable: \(refused.stderr)") }

print(failures == 0 ? "All deployment ssh checks passed." : "\(failures) deployment ssh check(s) failed.")
finish(failures == 0 ? 0 : 1)
