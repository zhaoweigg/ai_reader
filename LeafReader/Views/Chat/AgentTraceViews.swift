import SwiftUI
import UIKit

/// Book search agent limits and the troubleshooting entry in AI settings.
struct AgentLimitsSection: View {
    @Binding var configuration: ChatConfiguration

    var body: some View {
        Section {
            stepper("Tool calls per answer", value: $configuration.agentLimits.maxToolCalls, range: AgentLimits.toolCallRange, step: 1, id: "agentMaxToolCalls")
            stepper("Model rounds", value: $configuration.agentLimits.maxRounds, range: AgentLimits.roundRange, step: 1, id: "agentMaxRounds")
            stepper("Results per search", value: $configuration.agentLimits.resultsPerSearch, range: AgentLimits.resultRange, step: 1, id: "agentResultsPerSearch")
            stepper("Passage length", value: $configuration.agentLimits.passageLength, range: AgentLimits.passageRange, step: 500, unit: " chars", id: "agentPassageLength")
            stepper("Tool result limit", value: $configuration.agentLimits.toolResultLimit, range: AgentLimits.toolResultRange, step: 2000, unit: " chars", id: "agentToolResultLimit")
            stepper("Book preparation time", value: $configuration.agentLimits.preparationSeconds, range: AgentLimits.preparationRange, step: 5, unit: " s", id: "agentPreparation")
            Toggle("Search highlighted name first", isOn: $configuration.agentLimits.seedSearch).accessibilityIdentifier("agentSeedSearch")
        } header: { Text("Agent limits") }
        Section {
            ForEach((AgentTool.all + AgentTool.view + AgentTool.app + [AgentTool.webSearch]).map(\.name), id: \.self) { name in
                Toggle(name, isOn: Binding(get: { !configuration.agentLimits.disabledTools.contains(name) }, set: { on in
                    if on { configuration.agentLimits.disabledTools.remove(name) } else { configuration.agentLimits.disabledTools.insert(name) }
                })).font(.system(.body, design: .monospaced)).accessibilityIdentifier("agentTool-\(name)")
            }
        } header: { Text("Agent tools") } footer: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("Higher limits can give fuller answers but take longer and use more of your plan. web_search uses the web search of ChatGPT or Claude; other providers don’t offer it.")
                Button("Reset to defaults") { configuration.agentLimits = AgentLimits() }.font(.footnote).accessibilityIdentifier("agentLimitsReset")
            }
        }
    }
    private func stepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int, unit: String = "", id: String) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack { Text(title); Spacer(); Text(value.wrappedValue.formatted() + unit).foregroundStyle(.secondary).monospacedDigit() }
        }.accessibilityIdentifier(id)
    }
}

struct AgentTroubleshootingSection: View {
    @Binding var configuration: ChatConfiguration
    @EnvironmentObject private var traces: AgentTraceStore
    var body: some View {
        Section {
            Toggle("Record agent traces", isOn: $configuration.recordTraces).accessibilityIdentifier("recordAgentTraces")
            NavigationLink { AgentTracesView() } label: {
                HStack { Text("Agent traces"); Spacer(); Text(traces.traces.count.formatted()).foregroundStyle(.secondary) }
            }.accessibilityIdentifier("openAgentTraces")
        } header: { Text("Troubleshooting") } footer: {
            Text("Traces record each answer's prompt, searches, tool results, timing and token usage. They stay on this device (last \(AgentTraceStore.limit)) unless you share one.")
        }
    }
}

struct AgentTracesView: View {
    @Environment(\.leafTheme) private var theme
    @EnvironmentObject private var traces: AgentTraceStore
    private enum Filter: String, CaseIterable { case all = "All", agent = "Agent", plain = "No tools", failed = "Failed" }
    @State private var filter = Filter.all
    @State private var confirmClear = false
    private var visible: [AgentTrace] {
        traces.traces.filter { trace in
            switch filter {
            case .all: return true
            case .agent: return trace.harness == "agent"
            case .plain: return trace.harness != "agent"
            case .failed: return trace.outcome == .failed
            }
        }
    }
    var body: some View {
        List {
            Section {
                Picker("Filter", selection: $filter) { ForEach(Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).accessibilityIdentifier("agentTraceFilter")
            }.listRowBackground(Color.clear)
            if visible.isEmpty {
                ContentUnavailableView("No traces", systemImage: "list.bullet.rectangle", description: Text("Ask Leaf a question while Record agent traces is on."))
            }
            ForEach(visible) { trace in
                NavigationLink { AgentTraceDetailView(trace: trace) } label: { AgentTraceRow(trace: trace) }
                    .listRowBackground(theme.surface).accessibilityIdentifier("agentTrace-\(trace.id.uuidString)")
            }
        }
        .scrollContentBackground(.hidden).background(theme.canvas)
        .navigationTitle("Agent traces").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Clear", role: .destructive) { confirmClear = true }.disabled(traces.traces.isEmpty) } }
        .confirmationDialog("Delete all agent traces?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Delete all traces", role: .destructive) { traces.clear() }
        }
    }
}

private struct AgentTraceRow: View {
    let trace: AgentTrace
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                TraceBadge(trace: trace)
                Text([trace.bookTitle, trace.chapter].filter { !$0.isEmpty }.joined(separator: " · ")).lineLimit(1)
                Spacer()
                Text(trace.date, style: .time)
            }.font(.caption).foregroundStyle(.secondary)
            Text(trace.headline).font(.subheadline.weight(.semibold)).lineLimit(2)
            Text(trace.metrics).font(.caption).foregroundStyle(trace.harness == "agent" && trace.modelToolCalls == 0 && trace.outcome != .failed ? .orange : .secondary).lineLimit(2)
        }.padding(.vertical, 2)
    }
}

private struct TraceBadge: View {
    let trace: AgentTrace
    var body: some View {
        let (title, color): (String, Color) = trace.outcome == .failed ? ("Failed", .orange) : trace.harness == "agent" ? ("Agent", .teal) : trace.harness == "evidence" ? ("Pre-fetched", .gray) : ("No tools", .gray)
        Text(title).font(.caption2.weight(.semibold)).padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule()).foregroundStyle(color)
    }
}

struct AgentTraceDetailView: View {
    @Environment(\.leafTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var traces: AgentTraceStore
    let trace: AgentTrace
    @State private var copied = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text([trace.bookTitle, trace.chapter, trace.date.formatted(date: .omitted, time: .shortened), trace.model, trace.provider]
                        .filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    Text(trace.headline).font(.headline)
                    if let error = trace.error { Text(error).font(.caption).foregroundStyle(.orange) }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6) {
                    tile("\(trace.rounds)", "rounds"); tile("\(trace.toolCalls)", "tool calls"); tile(String(format: "%.1f s", trace.totalSeconds), "total")
                    tile(Self.compact(trace.charactersSent), "chars sent")
                    tile(trace.usage.input.map(Self.compact) ?? "–", "input tokens"); tile(trace.usage.output.map(Self.compact) ?? "–", "output tokens")
                }.accessibilityElement(children: .combine).accessibilityIdentifier("agentTraceSummary")
                if trace.usage.isEmpty {
                    Text("The provider did not report token usage for this answer.").font(.caption).foregroundStyle(.secondary)
                } else if trace.usage.cachedInput != nil || trace.usage.reasoning != nil {
                    Text(["cached input \(trace.usage.cachedInput?.formatted() ?? "–")", "reasoning \(trace.usage.reasoning?.formatted() ?? "–")"].joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let limits = trace.limits {
                    Text("Limits: \(limits.summary)\(limits.seedSearch ? "" : " · no seed search")\(limits.disabledTools.isEmpty ? "" : " · off: \(limits.disabledTools.sorted().joined(separator: ", "))")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.listRowBackground(theme.surface)
            Section("Steps") {
                ForEach(Array(trace.steps.enumerated()), id: \.element.id) { index, step in
                    AgentTraceStepRow(step: step, number: index + 1)
                }
            }.listRowBackground(theme.surface)
            Section {
                Button(copied ? "Copied" : "Copy JSON", systemImage: "doc.on.doc") { UIPasteboard.general.string = trace.json; copied = true }
                    .accessibilityIdentifier("copyAgentTrace")
                Button("Delete trace", systemImage: "trash", role: .destructive) { traces.remove(trace.id); dismiss() }
            }.listRowBackground(theme.surface)
        }
        .scrollContentBackground(.hidden).background(theme.canvas)
        .navigationTitle("Trace").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { ShareLink(item: trace.json, preview: SharePreview("Leaf agent trace")) } }
    }
    private func tile(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity).padding(.vertical, 8).background(theme.canvas, in: .rect(cornerRadius: 10))
    }
    static func compact(_ value: Int) -> String {
        value >= 10_000 ? String(format: "%.1fk", Double(value) / 1000) : value.formatted()
    }
}

private struct AgentTraceStepRow: View {
    let step: AgentTrace.Step
    let number: Int
    @State private var expanded = false
    private var symbol: (String, Color) {
        switch step.kind {
        case .context: return ("\(number)", .gray)
        case .seed: return ("S", .teal)
        case .round: return ("R", .indigo)
        case .tool: return ("T", .teal)
        case .answer: return ("A", .purple)
        case .lookup: return ("L", .teal)
        case .error: return ("!", .orange)
        case .request: return ("↻", .blue)
        }
    }
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(symbol.0).font(.caption2.weight(.bold)).foregroundStyle(.white).frame(width: 22, height: 22).background(symbol.1, in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(step.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(String(format: "%.1f s", step.seconds)).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
                if !step.withdrawn.isEmpty {
                    Text(step.withdrawn).strikethrough().font(.caption).foregroundStyle(.tertiary) + Text("  (withdrawn)").font(.caption).foregroundStyle(.secondary)
                }
                if !step.detail.isEmpty {
                    Text(step.detail).font(step.kind == .round ? .caption.monospaced() : .caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let usage = step.usage {
                    Text(Self.usageText(usage)).font(.caption2).foregroundStyle(.secondary).accessibilityIdentifier("agentTraceStepUsage-\(number)")
                }
                if !step.payload.isEmpty {
                    DisclosureGroup(isExpanded: $expanded) {
                        Text(step.payload.prefix(40000)).font(.caption2.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: { Text(step.payloadTitle.isEmpty ? "Details" : step.payloadTitle).font(.caption) }
                }
            }
        }.padding(.vertical, 2)
    }
    static func usageText(_ usage: TokenUsage) -> String {
        var parts = ["↑ \(usage.input?.formatted() ?? "–") in", "↓ \(usage.output?.formatted() ?? "–") out"]
        if let cached = usage.cachedInput { parts.append("cached \(cached.formatted())") }
        if let reasoning = usage.reasoning { parts.append("reasoning \(reasoning.formatted())") }
        return parts.joined(separator: " · ") + " tokens"
    }
}

extension AgentTrace {
    var headline: String {
        if let selection, !selection.isEmpty { return "“\(selection.prefix(40))” · \(question)" }
        return question
    }
    var metrics: String {
        if outcome == .failed { return [model, error ?? "failed"].filter { !$0.isEmpty }.joined(separator: " · ") }
        var parts = [model]
        if harness == "agent" { parts += ["\(rounds) \(rounds == 1 ? "round" : "rounds")", "\(modelToolCalls) \(modelToolCalls == 1 ? "tool" : "tools")"] }
        else if let lookup = steps.first(where: { $0.kind == .lookup }) { parts.append(lookup.title.lowercased()) }
        parts.append(String(format: "%.1f s", totalSeconds))
        if let input = usage.input, let output = usage.output { parts.append("\(AgentTraceDetailView.compact(input)) / \(AgentTraceDetailView.compact(output)) tokens") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
