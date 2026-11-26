import SwiftUI
import SocialForgeKit

/// Persists user-configured external MCP servers (e.g., ArtCraft or custom creative MCP servers).
enum OutboundMCPStore {
    private static let key = "outbound.mcp.servers.v1"

    static func load() -> [OutboundMCPServer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([OutboundMCPServer].self, from: data) else { return [] }
        return list
    }

    static func save(_ servers: [OutboundMCPServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func tokenKey(for serverID: String) -> String { "mcp.outbound.token.\(serverID)" }
}

/// Connections › Automation & Agents UI for configuring controlled external creative MCP servers.
struct OutboundMCPSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var servers: [OutboundMCPServer] = OutboundMCPStore.load()
    @State private var editing: OutboundMCPServer?
    @State private var discoveredTools: [String: [OutboundMCPTool]] = [:]
    @State private var statuses: [String: String] = [:]
    @State private var errors: [String: String] = [:]
    @State private var testingID: String?
    @State private var runTarget: (server: OutboundMCPServer, tool: OutboundMCPTool)?
    @State private var runArgsJSON = "{}"
    @State private var runOutput: OutboundMCPToolResult?
    @State private var runningTool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("External Creative MCP Servers").font(DS.bodyMedium)
                    Text("Connect optional user-configured MCP servers (such as ArtCraft or local creative tools) to generate or transform assets into your Media Library. External tools never publish or bypass review.")
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                Spacer()
                Button {
                    editing = OutboundMCPServer(name: "ArtCraft Creative MCP", transport: .stdio, command: "", arguments: [], restrictedRootPath: model.storage.root.path, requireApproval: true)
                } label: { Label("Add Server", systemImage: "plus") }
                    .buttonStyle(SecondaryButtonStyle())
            }

            if servers.isEmpty {
                HStack(spacing: Space.md) {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(DS.text3)
                    Text("No external MCP servers configured. Add one to discover creative tools and import approved outputs into your Media Library.")
                        .font(DS.small).foregroundStyle(DS.text2)
                }
                .padding(Space.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl, style: .continuous))
            } else {
                ForEach(servers) { server in
                    VStack(alignment: .leading, spacing: Space.sm) {
                        HStack(spacing: Space.md) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.sm) {
                                    Text(server.name).font(DS.bodyMedium)
                                    Text(server.transport.rawValue.uppercased()).font(DS.caption).foregroundStyle(DS.text3)
                                        .padding(.horizontal, Space.sm).padding(.vertical, Space.xs)
                                        .background(DS.fillStrong, in: Capsule())
                                    if server.requireApproval {
                                        Text("Approval required").font(DS.caption).foregroundStyle(DS.amber)
                                    }
                                }
                                Text(server.transport == .stdio ? (server.command.isEmpty ? "No command set" : server.command) : server.endpointURL)
                                    .font(DS.mono).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.middle)
                                if let s = statuses[server.id] {
                                    Text(s).font(DS.small).foregroundStyle(DS.green)
                                }
                                if let e = errors[server.id] {
                                    Text(e).font(DS.small).foregroundStyle(DS.red)
                                }
                            }
                            Spacer()
                            Button(testingID == server.id ? "Testing…" : "Test & Discover") {
                                Task { await discover(server) }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(testingID != nil || !server.enabled)
                            Button("Edit") { editing = server }.buttonStyle(SecondaryButtonStyle())
                            Button("Remove", role: .destructive) { remove(server) }.buttonStyle(SecondaryButtonStyle())
                        }

                        if let tools = discoveredTools[server.id], !tools.isEmpty {
                            Divider().overlay(DS.stroke)
                            VStack(alignment: .leading, spacing: Space.xs) {
                                Text("Discovered tools (\(tools.count))").font(DS.caption).foregroundStyle(DS.text3)
                                ForEach(tools) { tool in
                                    HStack(spacing: Space.sm) {
                                        let allowed = server.allowedTools.isEmpty || server.allowedTools.contains(tool.name)
                                        Toggle(isOn: Binding(
                                            get: { allowed },
                                            set: { on in toggleTool(tool.name, allowed: on, for: server.id, allTools: tools.map(\.name)) }
                                        )) {
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(tool.name).font(DS.mono)
                                                if !tool.description.isEmpty {
                                                    Text(tool.description).font(DS.caption).foregroundStyle(DS.text2).lineLimit(2)
                                                }
                                            }
                                        }
                                        .toggleStyle(SFToggleStyle())
                                        Spacer()
                                        Button("Run…") {
                                            runArgsJSON = "{}"
                                            runOutput = nil
                                            runTarget = (server, tool)
                                        }
                                        .buttonStyle(SecondaryButtonStyle())
                                        .disabled(!allowed || !server.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .card(padding: Space.md)
                }
            }
        }
        .sheet(item: $editing) { server in
            OutboundMCPEditorSheet(server: server) { updated, token in
                if let idx = servers.firstIndex(where: { $0.id == updated.id }) {
                    servers[idx] = updated
                } else {
                    servers.append(updated)
                }
                if let token {
                    Keychain.write(OutboundMCPStore.tokenKey(for: updated.id), token)
                }
                OutboundMCPStore.save(servers)
                editing = nil
            }
        }
        .sheet(isPresented: Binding(get: { runTarget != nil }, set: { if !$0 { runTarget = nil } })) {
            if let target = runTarget {
                VStack(alignment: .leading, spacing: Space.md) {
                    Text("Run \(target.tool.name)").font(DS.display(22))
                    Text("Server: \(target.server.name). Outputs are treated as untrusted until you review and import them into your library.")
                        .font(DS.small).foregroundStyle(DS.text2)
                    Text("Arguments (JSON object)").font(DS.small).foregroundStyle(DS.text2)
                    TextEditor(text: $runArgsJSON).font(DS.mono).frame(height: 112)
                        .padding(Space.xs).background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl))
                    if let out = runOutput {
                        VStack(alignment: .leading, spacing: Space.xs) {
                            Text(out.isError ? "Tool returned an error" : "Tool output").font(DS.small).foregroundStyle(out.isError ? DS.red : DS.green)
                            ScrollView { Text(out.text.isEmpty ? "(empty response)" : out.text).font(DS.mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 140).padding(Space.sm).background(DS.fill, in: RoundedRectangle(cornerRadius: DS.radiusControl))
                            if !out.outputFilePaths.isEmpty {
                                Button("Import \(out.outputFilePaths.count) Output File(s) into Media Library") {
                                    let urls = out.outputFilePaths.map { URL(fileURLWithPath: $0) }
                                    Task {
                                        let imported = await model.importMedia(urls)
                                        for a in imported {
                                            a.tags.append("mcp")
                                            a.notes = "External MCP: \(target.server.name) · \(target.tool.name)"
                                        }
                                        try? model.context.save()
                                        model.log("Imported \(imported.count) file(s) from \(target.server.name)", symbol: "puzzlepiece.extension")
                                        runTarget = nil
                                    }
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                    }
                    HStack {
                        Spacer()
                        Button("Close") { runTarget = nil }.buttonStyle(SecondaryButtonStyle())
                        Button(runningTool ? "Running…" : (target.server.requireApproval ? "Approve & Run" : "Run")) {
                            Task { await executeTool(target.server, target.tool) }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(runningTool)
                    }
                }
                .padding(Space.xl)
                .frame(width: 520)
                .background(DS.panel)
            }
        }
    }

    private func discover(_ server: OutboundMCPServer) async {
        testingID = server.id
        errors[server.id] = nil
        statuses[server.id] = nil
        defer { testingID = nil }
        let token = Keychain.read(OutboundMCPStore.tokenKey(for: server.id))
        let client = OutboundMCPClient(server: server, bearerToken: token)
        do {
            let (info, tools) = try await client.discoverTools()
            discoveredTools[server.id] = tools
            statuses[server.id] = "Connected · \(info) · \(tools.count) tool\(tools.count == 1 ? "" : "s")"
        } catch {
            errors[server.id] = error.localizedDescription
        }
    }

    private func executeTool(_ server: OutboundMCPServer, _ tool: OutboundMCPTool) async {
        runningTool = true
        defer { runningTool = false }
        let args: [String: JSONValue]
        if let data = runArgsJSON.data(using: .utf8),
           let parsed = try? JSONDecoder().decode(JSONValue.self, from: data).objectValue {
            args = parsed
        } else {
            runOutput = OutboundMCPToolResult(serverName: server.name, toolName: tool.name, text: "Arguments must be a valid JSON object.", isError: true)
            return
        }
        let token = Keychain.read(OutboundMCPStore.tokenKey(for: server.id))
        let client = OutboundMCPClient(server: server, bearerToken: token)
        do {
            runOutput = try await client.callTool(name: tool.name, arguments: args)
            model.log("Ran external MCP tool \(server.name)/\(tool.name)", symbol: "puzzlepiece.extension")
        } catch {
            runOutput = OutboundMCPToolResult(serverName: server.name, toolName: tool.name, text: error.localizedDescription, isError: true)
        }
    }

    private func toggleTool(_ name: String, allowed: Bool, for serverID: String, allTools: [String]) {
        guard let idx = servers.firstIndex(where: { $0.id == serverID }) else { return }
        var list = servers[idx].allowedTools.isEmpty ? allTools : servers[idx].allowedTools
        if allowed {
            if !list.contains(name) { list.append(name) }
        } else {
            list.removeAll { $0 == name }
        }
        servers[idx].allowedTools = list
        OutboundMCPStore.save(servers)
    }

    private func remove(_ server: OutboundMCPServer) {
        servers.removeAll { $0.id == server.id }
        Keychain.write(OutboundMCPStore.tokenKey(for: server.id), "")
        OutboundMCPStore.save(servers)
    }
}

private struct OutboundMCPEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: OutboundMCPServer
    @State private var argsText: String
    @State private var token = ""
    let onSave: (OutboundMCPServer, String?) -> Void

    init(server: OutboundMCPServer, onSave: @escaping (OutboundMCPServer, String?) -> Void) {
        _server = State(initialValue: server)
        _argsText = State(initialValue: server.arguments.joined(separator: " "))
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("External MCP Server").font(DS.display(22))
            TextField("Display name (e.g. ArtCraft MCP)", text: $server.name).fieldStyle()
            Picker("Transport", selection: $server.transport) {
                Text("Stdio subprocess").tag(OutboundMCPTransport.stdio)
                Text("HTTP JSON-RPC").tag(OutboundMCPTransport.http)
            }.pickerStyle(.segmented)
            if server.transport == .stdio {
                TextField("Executable path (e.g. /usr/local/bin/artcraft-mcp)", text: $server.command).fieldStyle()
                TextField("Arguments (space-separated, optional)", text: $argsText).fieldStyle()
            } else {
                TextField("Endpoint URL (https://… or http://127.0.0.1:…)", text: $server.endpointURL).fieldStyle()
                SecureField("Bearer token (optional, stored in Keychain)", text: $token).fieldStyle()
            }
            TextField("Restrict file paths to folder (optional)", text: $server.restrictedRootPath).fieldStyle()
            Toggle("Require approval before invoking tools", isOn: $server.requireApproval).toggleStyle(SFToggleStyle())
            Toggle("Enabled", isOn: $server.enabled).toggleStyle(SFToggleStyle())
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SecondaryButtonStyle())
                Button("Save") {
                    var copy = server
                    copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    copy.command = copy.command.trimmingCharacters(in: .whitespacesAndNewlines)
                    copy.endpointURL = copy.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    copy.restrictedRootPath = copy.restrictedRootPath.trimmingCharacters(in: .whitespacesAndNewlines)
                    copy.arguments = argsText.split(whereSeparator: \.isWhitespace).map(String.init)
                    onSave(copy, server.transport == .http && !token.isEmpty ? token : nil)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
        .background(DS.panel)
    }
}
