import Foundation

/// One read-only look at a machine: the script that collects it (run with `sh -s`, locally or over SSH),
/// the parser of its output, and the health it adds up to. Foundation only, checked in
/// `tools/tests/system-probe-tests.sh` (the script runs on this Mac there).
struct SystemSnapshot: Equatable {
    struct Disk: Equatable { let mount: String; let sizeKB: Int64; let usedKB: Int64; let percent: Int }
    struct Process: Equatable { let pid: String; let cpu: Double; let memory: Double; let name: String }
    struct Container: Equatable { let name: String; let status: String; let image: String }
    struct CheckResult: Equatable {
        enum Status: String { case ok, fail, unknown }
        let id: String
        let status: Status
        let detail: String
    }
    enum Health: Int, Comparable {
        case ok, warning, critical
        static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }
    }

    var os = ""
    var host = ""
    var kernel = ""
    var uptimeSeconds: Int64 = 0
    var cpus = 0
    var load: [Double] = []
    var memTotalKB: Int64 = 0
    var memAvailableKB: Int64 = 0
    var disks: [Disk] = []
    var processes: [Process] = []
    var containers: [Container] = []
    var failedUnits: [String] = []
    var checks: [CheckResult] = []
    var collectedAt = Date()

    var memUsedKB: Int64 { max(0, memTotalKB - memAvailableKB) }
    var memUsedFraction: Double { memTotalKB > 0 ? Double(memUsedKB) / Double(memTotalKB) : 0 }
    /// Load of the last minute per CPU.
    var loadPerCPU: Double { (load.first ?? 0) / Double(max(cpus, 1)) }

    /// Disks at 80 % warn, 90 % are critical; memory above 90 %, a load above 1.5 per CPU and failed units
    /// warn (a load above 3 per CPU is critical); a failed check is critical.
    var health: Health {
        var worst = Health.ok
        func raise(_ h: Health) { if h > worst { worst = h } }
        for disk in disks { raise(disk.percent >= 90 ? .critical : disk.percent >= 80 ? .warning : .ok) }
        if memTotalKB > 0, memUsedFraction > 0.9 { raise(.warning) }
        if loadPerCPU > 3 { raise(.critical) } else if loadPerCPU > 1.5 { raise(.warning) }
        if !failedUnits.isEmpty { raise(.warning) }
        if checks.contains(where: { $0.status == .fail }) { raise(.critical) }
        return worst
    }

    /// What put the health where it is, one line each.
    var reasons: [String] {
        var lines: [String] = []
        for disk in disks where disk.percent >= 80 { lines.append("Disk \(disk.mount) is \(disk.percent) % full") }
        if memTotalKB > 0, memUsedFraction > 0.9 { lines.append("Memory is \(Int(memUsedFraction * 100)) % used") }
        if loadPerCPU > 1.5 { lines.append(String(format: "Load %.2f per CPU", loadPerCPU)) }
        if !failedUnits.isEmpty { lines.append("Failed units: " + failedUnits.joined(separator: ", ")) }
        for check in checks where check.status == .fail { lines.append("Check \(check.id) failed" + (check.detail.isEmpty ? "" : ": \(check.detail)")) }
        return lines
    }
}

enum SystemProbe {
    static let marker = "@@MV"

    // MARK: Script

    /// The script to run with `sh -s`. Everything in it only reads; the checks are generated from `checks`
    /// with every value single-quoted.
    static func script(checks: [DeploymentCheck] = [], includeSystem: Bool = true) -> String {
        var s = includeSystem ? base : helpers
        s += "\n"
        for check in checks { s += snippet(for: check) + "\n" }
        return s
    }

    /// Only what the checks need (a cloud environment is looked at from this Mac, not as a machine).
    private static let helpers = """
    LC_ALL=C; export LC_ALL
    chk() { printf '@@MV|check|%s|%s|%s\\n' "$1" "$2" "$3"; }
    """

    private static let base = """
    LC_ALL=C; export LC_ALL
    mv() { printf '@@MV|%s\\n' "$1"; }
    os=$(uname -s)
    mv "os|$os"
    mv "host|$(hostname 2>/dev/null)"
    mv "kernel|$(uname -r 2>/dev/null)"
    case "$os" in
    Linux)
      mv "uptime|$(cut -d. -f1 /proc/uptime 2>/dev/null)"
      mv "cpus|$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
      mv "load|$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
      mv "memtotal|$(grep '^MemTotal:' /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)"
      mv "memavail|$(grep '^MemAvailable:' /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)"
      ;;
    Darwin)
      boot=$(sysctl -n kern.boottime 2>/dev/null | sed 's/^{ *sec = \\([0-9]*\\),.*/\\1/')
      now=$(date +%s)
      [ -n "$boot" ] && mv "uptime|$((now - boot))"
      mv "cpus|$(sysctl -n hw.ncpu 2>/dev/null)"
      mv "load|$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | sed 's/^ *//' | cut -d' ' -f1-3)"
      mv "memtotal|$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 ))"
      pagesize=$(sysctl -n hw.pagesize 2>/dev/null || echo 4096)
      pages=$(vm_stat 2>/dev/null | grep -E '^Pages (free|inactive|speculative):' | tr -d '.' | tr -s ' ' | cut -d' ' -f3 | paste -sd+ - | sed 's/^$/0/')
      mv "memavail|$(( ($pages) * pagesize / 1024 ))"
      ;;
    esac
    df -Pk 2>/dev/null | tail -n +2 | while read fs size used avail pct mount rest; do
      case "$fs" in tmpfs|devtmpfs|overlay|map|devfs|none|squashfs|efivarfs) continue ;; esac
      case "$size" in ''|*[!0-9]*|0) continue ;; esac
      case "$pct" in *%) ;; *) continue ;; esac
      case "$mount" in /System/Volumes/*|/private/var/vm|/dev*|/run*|/snap*|/Library/Developer/*|/var/lib/docker/*|/boot/efi|/etc/*) continue ;; esac
      mv "disk|$mount|$size|$used|${pct%\\%}"
    done
    ps -eo pid=,pcpu=,pmem=,comm= 2>/dev/null | sort -k2 -nr | head -6 | while read pid cpu mem name; do mv "proc|$pid|$cpu|$mem|$name"; done
    if command -v docker >/dev/null 2>&1; then
      docker ps --format '{{.Names}}|{{.Status}}|{{.Image}}' 2>/dev/null | while IFS= read -r line; do mv "container|$line"; done
    fi
    if command -v systemctl >/dev/null 2>&1; then
      systemctl --failed --no-legend --plain 2>/dev/null | while read unit rest; do [ -n "$unit" ] && mv "failed|$unit"; done
    fi
    chk() { printf '@@MV|check|%s|%s|%s\\n' "$1" "$2" "$3"; }
    """

    /// Single-quote a value for a POSIX shell.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func snippet(for check: DeploymentCheck) -> String {
        let id = quoted(check.id)
        let target = quoted(check.target)
        switch check.kind {
        case .systemd:
            return "if systemctl is-active --quiet \(target) 2>/dev/null; then chk \(id) ok active; else chk \(id) fail \"$(systemctl is-active \(target) 2>&1 | head -1)\"; fi"
        case .docker:
            return "state=$(docker inspect -f '{{.State.Status}}' \(target) 2>&1 | head -1); if [ \"$state\" = running ]; then chk \(id) ok running; else chk \(id) fail \"$state\"; fi"
        case .port:
            let parts = check.target.split(separator: ":").map(String.init)
            let host = parts.count > 1 ? parts[0] : "localhost"
            let port = parts.last ?? ""
            return "if bash -c \(quoted("exec 3<>/dev/tcp/\(host)/\(port)")) 2>/dev/null || nc -z -w 3 \(quoted(host)) \(quoted(port)) 2>/dev/null; then chk \(id) ok listening; else chk \(id) fail closed; fi"
        case .http:
            let wanted = quoted(check.expect)
            return "code=$(curl -s -o /dev/null -m 8 -w '%{http_code}' \(target) 2>/dev/null); want=\(wanted); case \"$code\" in 000|'') chk \(id) fail 'no answer';; *) if [ -z \"$want\" ]; then case \"$code\" in 2*|3*) chk \(id) ok \"$code\";; *) chk \(id) fail \"$code\";; esac; else case \"$want\" in *x) pre=${want%xx}; case \"$code\" in $pre*) chk \(id) ok \"$code\";; *) chk \(id) fail \"$code\";; esac;; *) if [ \"$code\" = \"$want\" ]; then chk \(id) ok \"$code\"; else chk \(id) fail \"$code\"; fi;; esac; fi;; esac"
        case .postgres:
            return "if out=$(pg_isready \(check.target.isEmpty ? "" : check.target.split(separator: " ").map { quoted(String($0)) }.joined(separator: " ")) 2>&1); then chk \(id) ok \"$out\"; else chk \(id) fail \"$out\"; fi"
        case .redis:
            return "out=$(redis-cli \(check.target.isEmpty ? "" : check.target.split(separator: " ").map { quoted(String($0)) }.joined(separator: " ")) ping 2>&1 | head -1); if [ \"$out\" = PONG ]; then chk \(id) ok PONG; else chk \(id) fail \"$out\"; fi"
        case .mysql:
            return "if out=$(mysqladmin \(check.target.isEmpty ? "" : check.target.split(separator: " ").map { quoted(String($0)) }.joined(separator: " ")) ping 2>&1 | head -1); then chk \(id) ok \"$out\"; else chk \(id) fail \"$out\"; fi"
        case .command:
            // Only a read-only command runs by itself; the caller leaves the others out.
            let want = quoted(check.expect)
            return "res=$(sh -c \(target) 2>&1; printf '\\n@@RC=%s' \"$?\"); rc=${res##*@@RC=}; out=$(printf '%s' \"${res%@@RC=*}\" | head -c 400 | tr '\\n' ' '); want=\(want); if [ -n \"$want\" ]; then case \"$out\" in *\"$want\"*) chk \(id) ok \"$want\";; *) chk \(id) fail \"$out\";; esac; elif [ \"$rc\" = 0 ]; then chk \(id) ok 'exit 0'; else chk \(id) fail \"exit $rc: $out\"; fi"
        }
    }

    /// The checks that may run unattended: everything but a command that is not read-only.
    static func runnable(_ checks: [DeploymentCheck]) -> (run: [DeploymentCheck], held: [DeploymentCheck]) {
        var run: [DeploymentCheck] = [], held: [DeploymentCheck] = []
        for check in checks {
            if check.kind == .command, !CommandPolicy.classify(check.target).isReadOnly { held.append(check) } else { run.append(check) }
        }
        return (run, held)
    }

    // MARK: Parser

    static func parse(_ output: String, now: Date = Date()) -> SystemSnapshot {
        var snapshot = SystemSnapshot()
        snapshot.collectedAt = now
        for line in output.split(separator: "\n") where line.hasPrefix(marker + "|") {
            let fields = line.dropFirst(marker.count + 1).split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard let kind = fields.first else { continue }
            let rest = Array(fields.dropFirst())
            func int(_ i: Int) -> Int64 { i < rest.count ? Int64(rest[i].trimmingCharacters(in: .whitespaces)) ?? 0 : 0 }
            switch kind {
            case "os": snapshot.os = rest.first ?? ""
            case "host": snapshot.host = rest.first ?? ""
            case "kernel": snapshot.kernel = rest.first ?? ""
            case "uptime": snapshot.uptimeSeconds = int(0)
            case "cpus": snapshot.cpus = Int(int(0))
            case "load": snapshot.load = (rest.first ?? "").split(separator: " ").compactMap { Double($0) }
            case "memtotal": snapshot.memTotalKB = int(0)
            case "memavail": snapshot.memAvailableKB = int(0)
            case "disk":
                guard rest.count >= 4 else { continue }
                snapshot.disks.append(.init(mount: rest[0], sizeKB: int(1), usedKB: int(2), percent: Int(int(3))))
            case "proc":
                guard rest.count >= 4 else { continue }
                snapshot.processes.append(.init(pid: rest[0], cpu: Double(rest[1]) ?? 0, memory: Double(rest[2]) ?? 0, name: rest[3...].joined(separator: "|")))
            case "container":
                guard rest.count >= 2 else { continue }
                snapshot.containers.append(.init(name: rest[0], status: rest[1], image: rest.count > 2 ? rest[2] : ""))
            case "failed": if let unit = rest.first, !unit.isEmpty { snapshot.failedUnits.append(unit) }
            case "check":
                guard rest.count >= 2 else { continue }
                let status = SystemSnapshot.CheckResult.Status(rawValue: rest[1]) ?? .unknown
                snapshot.checks.append(.init(id: rest[0], status: status, detail: rest.count > 2 ? rest[2...].joined(separator: "|") : ""))
            default: continue
            }
        }
        return snapshot
    }

    /// "3 d 4 h", "5 h 12 min", "42 min".
    static func uptimeText(_ seconds: Int64) -> String {
        let days = seconds / 86_400, hours = seconds % 86_400 / 3600, minutes = seconds % 3600 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(minutes) min" }
        return "\(minutes) min"
    }
}
