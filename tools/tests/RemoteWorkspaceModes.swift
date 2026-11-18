import Foundation

/// Explicit manual command modes retained for the remote-workspace harness.
@main enum RemoteWorkspaceModes {
    static func main() throws {
        let args = CommandLine.arguments
        if args.contains("--remote-workspace-mcp") { RemoteUnixRPC.runMCP(arguments: args) }
        if args.contains("--remote-workspace-guard") { RemoteUnixRPC.runGuard() }
        if let index = args.firstIndex(of: "--provider-command"), args.count > index + 4 {
            let directory = URL(fileURLWithPath: args[index + 4])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            print(try RemoteProviderConfiguration.command(tool: RemoteProviderConfiguration.tool(named: args[index + 1])!, executable: args[index + 2],
                app: args[index + 3], socket: directory.appendingPathComponent("test.sock").path,
                context: .object(["cwd": .string("/test/work"), "hostname": .string("test-work")]), directory: directory, model: nil, resume: false))
            return
        }
        throw RemoteFailure.invalid("Unknown remote workspace harness command")
    }
}
