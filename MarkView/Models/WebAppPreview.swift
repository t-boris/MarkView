import Foundation

/// A web application of the project that can be previewed: where it is, the command that
/// starts its development server, and the ports it is expected to answer on.
struct WebAppTarget: Equatable {
    /// The folder of the app (the project root or one of its packages).
    var folder: URL
    /// Shown when the project holds several apps ("web", "apps/site").
    var label: String
    /// Typed into a terminal in `folder`, e.g. `npm run dev`.
    var command: String
    /// Ports named by the scripts or the config first, then the framework's default.
    var ports: [Int]
}

/// Finds the project's web apps and their development servers (Preview Web App).
enum WebAppPreview {
    /// Ports tried when the project gives no hint: Vite, Next / CRA / Rails, Angular,
    /// Vue CLI / webpack, Astro, Django, Flask, Storybook, Parcel.
    static let commonPorts = [5173, 3000, 4200, 8080, 4321, 8000, 5000, 6006, 1234, 3001, 5174, 8081]

    // MARK: - Discovery

    /// Apps in the project root and up to two levels down (`web/`, `apps/site/`), the root first.
    static func targets(root: URL, fileManager: FileManager = .default) -> [WebAppTarget] {
        var folders = [root]
        let skip: Set<String> = ["node_modules", "build", "dist", "out", "target", "vendor", "Pods", ".git", "DerivedData"]
        func children(_ folder: URL) -> [URL] {
            ((try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? [])
                .filter { !skip.contains($0.lastPathComponent) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for child in children(root) {
            folders.append(child)
            folders.append(contentsOf: children(child))
        }
        return folders.compactMap { target(in: $0, root: root, fileManager: fileManager) }
    }

    /// The app in `folder`, when it has a recognised development server.
    static func target(in folder: URL, root: URL, fileManager: FileManager = .default) -> WebAppTarget? {
        let relative = folder.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let label = relative.isEmpty ? root.lastPathComponent : relative
        if let package = readJSON(folder.appendingPathComponent("package.json")),
           let target = nodeTarget(package, folder: folder, label: label, fileManager: fileManager) {
            return target
        }
        let exists = { (name: String) in fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) }
        if exists("manage.py") {
            return WebAppTarget(folder: folder, label: label, command: "python3 manage.py runserver", ports: [8000])
        }
        if exists("bin/rails") {
            return WebAppTarget(folder: folder, label: label, command: "bin/rails server", ports: [3000])
        }
        if exists("index.html") && !exists("package.json") && folder == root {
            // A static site: serve the folder.
            return WebAppTarget(folder: folder, label: label, command: "python3 -m http.server 8000", ports: [8000])
        }
        return nil
    }

    private static func nodeTarget(_ package: [String: Any], folder: URL, label: String,
                                   fileManager: FileManager) -> WebAppTarget? {
        let scripts = package["scripts"] as? [String: String] ?? [:]
        guard let name = ["dev", "start", "serve", "develop", "preview"].first(where: { scripts[$0] != nil }),
              let script = scripts[name] else { return nil }
        let dependencies = ((package["dependencies"] as? [String: Any]) ?? [:])
            .merging((package["devDependencies"] as? [String: Any]) ?? [:]) { first, _ in first }
        // A library or a CLI also has "start"; a web app names a web framework or server.
        let web = ["vite", "next", "react-scripts", "@angular/core", "@vue/cli-service", "nuxt", "astro",
                   "@sveltejs/kit", "svelte", "@remix-run/dev", "gatsby", "parcel", "webpack-dev-server",
                   "express", "fastify", "koa", "@nestjs/core", "hono", "solid-start", "@builder.io/qwik",
                   "@docusaurus/core", "vitepress", "@storybook/react", "http-server", "serve", "live-server"]
        let isWeb = web.contains { dependencies[$0] != nil }
            || ["vite", "next", "ng serve", "nuxt", "astro", "webpack", "parcel", "remix", "gatsby"].contains { script.contains($0) }
        guard isWeb else { return nil }
        let exists = { (name: String) in fileManager.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let manager: String
        if exists("pnpm-lock.yaml") { manager = "pnpm" }
        else if exists("yarn.lock") { manager = "yarn" }
        else if exists("bun.lockb") || exists("bun.lock") { manager = "bun" }
        else { manager = "npm" }
        let command = manager == "npm" && name == "start" ? "npm start" : "\(manager) run \(name)"
        var ports = explicitPorts(in: script)
        for config in ["vite.config.ts", "vite.config.js", "vite.config.mjs", "vite.config.mts", "angular.json",
                       "astro.config.mjs", "astro.config.ts", "nuxt.config.ts", "vue.config.js"] {
            if let text = try? String(contentsOf: folder.appendingPathComponent(config), encoding: .utf8) {
                ports += configPorts(in: text)
            }
        }
        ports += defaultPorts(script: script, dependencies: Set(dependencies.keys))
        return WebAppTarget(folder: folder, label: label, command: command, ports: unique(ports))
    }

    /// `--port 4000`, `-p 4000`, `--port=4000`, `PORT=4000`.
    static func explicitPorts(in script: String) -> [Int] {
        let pattern = #"(?:--port[= ]|-p |PORT=)(\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(script.startIndex..., in: script)
        return regex.matches(in: script, range: range).compactMap { match in
            Range(match.range(at: 1), in: script).flatMap { Int(script[$0]) }
        }.filter { (1...65535).contains($0) }
    }

    /// `port: 4000` / `"port": 4000` in a framework config.
    static func configPorts(in text: String) -> [Int] {
        let pattern = #"["']?port["']?\s*:\s*(\d{2,5})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }.filter { (1...65535).contains($0) }
    }

    private static func defaultPorts(script: String, dependencies: Set<String>) -> [Int] {
        if script.contains("storybook") { return [6006] }
        if dependencies.contains("@angular/core") || script.contains("ng serve") { return [4200] }
        if dependencies.contains("astro") { return [4321] }
        if dependencies.contains("@vue/cli-service") { return [8080] }
        if dependencies.contains("vite") || dependencies.contains("@sveltejs/kit") || script.contains("vite") { return [5173, 5174] }
        if dependencies.contains("next") || dependencies.contains("react-scripts") || dependencies.contains("nuxt")
            || dependencies.contains("@remix-run/dev") || dependencies.contains("express") { return [3000, 3001] }
        if dependencies.contains("gatsby") { return [8000] }
        if dependencies.contains("parcel") { return [1234] }
        return [3000, 5173, 8080]
    }

    // MARK: - Terminal output

    /// The first address of this machine in a development server's output
    /// ("Local:   http://localhost:5173/"); terminal colour codes are ignored and 0.0.0.0
    /// becomes localhost.
    static func firstLocalURL(in output: String) -> URL? {
        let plain = output.replacingOccurrences(of: #"\x{1B}\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
        let pattern = #"https?://(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\])(?::\d{2,5})?(?:/[^\s'"<>)\]]*)?"#
        guard let range = plain.range(of: pattern, options: .regularExpression) else { return nil }
        var text = String(plain[range])
        while let last = text.last, ".,;:".contains(last) { text.removeLast() }
        text = text.replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
            .replacingOccurrences(of: "://[::]", with: "://localhost")
        return URL(string: text)
    }

    // MARK: - Probing

    /// The first of `ports` where an HTTP server answers on localhost, in the given order.
    static func firstAnswering(_ ports: [Int], timeout: TimeInterval = 0.8) async -> URL? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let answers = await withTaskGroup(of: (Int, Bool).self) { group in
            for port in ports {
                group.addTask {
                    guard let url = URL(string: "http://localhost:\(port)/") else { return (port, false) }
                    var request = URLRequest(url: url)
                    request.httpMethod = "GET"
                    request.setValue("MarkView preview probe", forHTTPHeaderField: "User-Agent")
                    let response = try? await session.data(for: request).1
                    return (port, response is HTTPURLResponse)
                }
            }
            var answering = Set<Int>()
            for await (port, ok) in group where ok { answering.insert(port) }
            return answering
        }
        return ports.first(where: answers.contains).flatMap { URL(string: "http://localhost:\($0)/") }
    }

    // MARK: - Helpers

    private static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func unique(_ ports: [Int]) -> [Int] {
        var seen = Set<Int>()
        return ports.filter { seen.insert($0).inserted }
    }
}
