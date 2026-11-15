import SwiftUI

/// Every field edits the saved request, so approval and replay always refer to what the person sees.
struct QAAPIRequestEditor: View {
    @Environment(\.palette) private var palette
    @ObservedObject var model: QAModel
    let node: QANode

    private var request: QAAPIRequest { model.current?.node(node.id)?.api ?? QAAPIRequest() }

    private func field<T>(_ path: WritableKeyPath<QAAPIRequest, T>) -> Binding<T> {
        Binding(get: { request[keyPath: path] }, set: { value in
            model.edit { $0.update(node: node.id) { node in
                var api = node.api ?? QAAPIRequest(); api[keyPath: path] = value; node.api = api
            } }
        })
    }

    private func change(_ edit: (inout QAAPIRequest) -> Void) {
        model.edit { $0.update(node: node.id) { node in
            var api = node.api ?? QAAPIRequest(); edit(&api); node.api = api
        } }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("HTTP request and response checks").uiFont(size: 11.5, weight: .semibold)
            Toggle("Execute API step", isOn: Binding(get: { node.api != nil }, set: { enabled in
                model.edit { $0.update(node: node.id) { $0.api = enabled ? QAAPIRequest() : nil } }
            }))
            if node.api != nil {
                Picker("Method", selection: field(\.method)) {
                    ForEach(["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"], id: \.self) { Text($0).tag($0) }
                }
                Text("Request path").uiFont(size: 10.5)
                TextField("Path, e.g. /items/{{itemId}}", text: field(\.path)).textFieldStyle(.roundedBorder)
                Text("Leave the path empty to check this player's previous response. A relative path uses the service base URL.")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                headers
                Text("Request body").uiFont(size: 10.5)
                TextEditor(text: field(\.body)).font(.system(size: 11, design: .monospaced)).frame(minHeight: 65)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(palette.border))
                Text("Use {{username}} / {{password}} from a saved login and {{captureName}} from an earlier response. Use {{captureName.json}} for an escaped JSON value.")
                    .uiFont(size: 10).foregroundColor(palette.textDim)
                Text("Expected HTTP statuses").uiFont(size: 10.5)
                TextField("Expected statuses (comma separated)", text: Binding(get: { request.statuses.map(String.init).joined(separator: ", ") }, set: { value in
                    change { $0.statuses = value.components(separatedBy: ",").map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 } }
                })).textFieldStyle(.roundedBorder)
                Stepper("Timeout: \(request.timeoutSeconds) seconds", value: field(\.timeoutSeconds), in: 1...120).uiFont(size: 10.5)
                assertions
                captures
                ForEach(Array(request.problems.enumerated()), id: \.offset) { _, problem in
                    Text(problem).uiFont(size: 10).foregroundColor(palette.red)
                }
            }
        }
    }

    private var headers: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Headers").uiFont(size: 10.5)
                Spacer()
                Button("Add") { change { $0.headers.append(.init(name: "", value: "")) } }.uiFont(size: 10)
            }
            ForEach(Array(request.headers.indices), id: \.self) { index in
                VStack(spacing: 4) {
                    HStack {
                        TextField("Name", text: header(index, \.name)).textFieldStyle(.roundedBorder)
                        Button { change { $0.headers.remove(at: index) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    TextField("Value or {{token}}", text: header(index, \.value)).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func header(_ index: Int, _ path: WritableKeyPath<QAAPIRequest.Header, String>) -> Binding<String> {
        Binding(get: { request.headers.indices.contains(index) ? request.headers[index][keyPath: path] : "" }, set: { value in
            change { if $0.headers.indices.contains(index) { $0.headers[index][keyPath: path] = value } }
        })
    }

    private var assertions: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("JSON assertions").uiFont(size: 10.5)
                Spacer()
                Button("Add") { change { $0.assertions.append(.init(pointer: "/id", equals: "null")) } }.uiFont(size: 10)
            }
            Text("JSON Pointer → expected JSON literal (e.g. /name → \"Alice\", /active → true)").uiFont(size: 10).foregroundColor(palette.textDim)
            ForEach(Array(request.assertions.indices), id: \.self) { index in
                VStack(spacing: 4) {
                    HStack {
                        TextField("/path", text: assertion(index, \.pointer)).textFieldStyle(.roundedBorder)
                        Button { change { $0.assertions.remove(at: index) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    TextField("Expected JSON", text: assertion(index, \.equals)).textFieldStyle(.roundedBorder)
                }
            }
        }
    }

    private func assertion(_ index: Int, _ path: WritableKeyPath<QAAPIRequest.Assertion, String>) -> Binding<String> {
        Binding(get: { request.assertions.indices.contains(index) ? request.assertions[index][keyPath: path] : "" }, set: { value in
            change { if $0.assertions.indices.contains(index) { $0.assertions[index][keyPath: path] = value } }
        })
    }

    private func capture(_ index: Int, _ path: WritableKeyPath<QAAPIRequest.Capture, String>) -> Binding<String> {
        Binding(get: { request.captures.indices.contains(index) ? request.captures[index][keyPath: path] : "" }, set: { value in
            change { if $0.captures.indices.contains(index) { $0.captures[index][keyPath: path] = value } }
        })
    }

    private var captures: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("Capture response values").uiFont(size: 10.5)
                Spacer()
                Button("Add") { change { $0.captures.append(.init(name: "value", pointer: "/id")) } }.uiFont(size: 10)
            }
            ForEach(Array(request.captures.indices), id: \.self) { index in
                VStack(spacing: 4) {
                    HStack {
                        TextField("Variable name", text: capture(index, \.name)).textFieldStyle(.roundedBorder)
                        Button { change { $0.captures.remove(at: index) } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                    }
                    TextField("/response/path", text: capture(index, \.pointer)).textFieldStyle(.roundedBorder)
                    Toggle("Secret (hide from reports)", isOn: Binding(get: { request.captures.indices.contains(index) && request.captures[index].secret }, set: { value in
                        change { if $0.captures.indices.contains(index) { $0.captures[index].secret = value } }
                    })).uiFont(size: 10.5)
                }
            }
        }
    }
}
