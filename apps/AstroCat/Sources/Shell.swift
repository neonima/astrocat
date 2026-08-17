import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case library, stack, develop, insights

    var id: String { rawValue }

    var label: String {
        switch self {
        case .library: return "Library"
        case .stack: return "Stack"
        case .develop: return "Develop"
        case .insights: return "Insights"
        }
    }

    var sidebarWidth: CGFloat? {
        switch self {
        case .library, .develop: return 240
        case .stack, .insights: return 300
        }
    }

    var inspectorWidth: CGFloat {
        switch self {
        case .library, .stack, .develop: return 316
        case .insights: return 380
        }
    }
}

@MainActor
final class ShellModel: ObservableObject {
    @Published var module: Module = .library
    @Published var showProjects = true
    @Published var showImport = false
    @Published var inspectorVisible = true
    @Published var metric: TraceMetric = .stars
    @Published var cutWorst: Float = 0
    /// Number of worst-ranked frames the cut selects. Drives selection, not just a preview.
    @Published var rankSelection = 0
    /// A named selection from the sidebar, resolved against the catalog.
    @Published var namedSelection: String?
    /// Narrows what every Library view shows — distinct from selection, which
    /// picks frames out of what is shown.
    @Published var activeFilters: Set<String> = []
    /// Sky events whose frames are hidden — set by clicking the trace labels.
    @Published var excludedEvents: Set<String> = []
    @Published var excludeDefects = false
    @Published var nightVision = false
    @Published var libraryView: LibraryView = .trace
    @Published var threshold: Float = 0
    @Published var cursor = 0
    @Published var anchor: Int?

    var tokens: Tokens { nightVision ? .nightVision : .dark }
}

struct AppShell: View {
    @StateObject private var shell = ShellModel()
    @StateObject private var catalog = Catalog()
    @StateObject private var store = ProjectStore()
    @StateObject private var importer = ImportModel()
    @StateObject private var stacker = StackModel()
    @StateObject private var developer = DevelopModel()
    /// Owned by the shell so it survives module switches — a per-module
    /// StateObject is destroyed on every navigation and loses its cache.
    @StateObject private var thumbs = ThumbnailStore()
    /// Held here too: a multi-minute download must survive a module switch.
    @StateObject private var sky = SkyCatalogue()

    var body: some View {
        let t = shell.tokens

        VStack(spacing: 0) {
            TitleBar(shell: shell, catalog: catalog)
            Divider().overlay(t.line)
            SubToolbar(shell: shell, catalog: catalog)
            Divider().overlay(t.line)

            Group {
                if shell.showProjects {
                    HomeModule(store: store, catalog: catalog, shell: shell)
                } else if shell.showImport {
                    ImportModule(model: importer, catalog: catalog)
                } else {
                    switch shell.module {
                    case .library: LibraryModule(catalog: catalog, shell: shell, thumbs: thumbs)
                    case .stack: StackModule(model: stacker, catalog: catalog)
                    case .develop: DevelopModule(model: developer, stacker: stacker, sky: sky)
                    case .insights: PlaceholderModule(module: shell.module)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider().overlay(t.line)
            StatusBar(shell: shell, catalog: catalog)
        }
        .background(t.s0)
        .environment(\.tokens, t)
        .preferredColorScheme(.dark)
        .onAppear {
            let seed = "/Users/vinny/proj/astrocat/samples/na nebula"
            catalog.open(seed)
            thumbs.project = seed
            store.load(seeding: seed)
            sky.open()
            stacker.projectRoot = seed
            importer.scan(seed, project: seed)
        }
    }
}

struct TitleBar: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var catalog: Catalog
    @Environment(\.tokens) private var t

    var body: some View {
        ZStack {
            Segmented(
                items: Module.allCases.map(\.label),
                index: Binding(
                    get: { Module.allCases.firstIndex(of: shell.module) ?? 0 },
                    set: {
                        shell.module = Module.allCases[$0]
                        shell.showProjects = false
                        shell.showImport = false
                    }),
                height: 22, font: Face.body, padding: Space.lg)

            HStack(spacing: Space.lg) {
                Button {
                    shell.showProjects.toggle()
                    shell.showImport = false
                } label: {
                    HStack(spacing: Space.xs) {
                        RoundedRectangle(cornerRadius: 1)
                            .stroke(t.t2, lineWidth: 1)
                            .frame(width: 9, height: 9)
                        Text("Projects").font(Face.body).foregroundStyle(t.t1)
                    }
                    .padding(.horizontal, Space.md)
                    .frame(height: 20)
                    .background(shell.showProjects ? t.sel : t.s2)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(t.line2, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 0) {
                    Text(context.0).font(Face.title).foregroundStyle(t.t1)
                    Text(context.1).font(Face.mono(10)).foregroundStyle(t.t3)
                }

                Spacer()

                Button { shell.nightVision.toggle() } label: {
                    Text("NIGHT")
                        .font(Face.sectionHeader).tracking(Face.sectionTracking)
                        .foregroundStyle(shell.nightVision ? t.selT : t.t3)
                        .padding(.horizontal, Space.md)
                        .frame(height: 18)
                        .background(shell.nightVision ? t.sel : t.s2)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.control)
                                .stroke(shell.nightVision ? t.selLine : t.line2, lineWidth: 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                }
                .buttonStyle(.plain)

                Button { shell.inspectorVisible.toggle() } label: {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(t.t2, lineWidth: 1)
                        .frame(width: 16, height: 12)
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(shell.inspectorVisible ? t.t2 : .clear)
                                .frame(width: 5)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, Metric.trafficLightInset)
        .padding(.trailing, Metric.panelPad)
        .frame(height: Metric.toolbar)
        .background(t.s1)
    }

    private var context: (String, String) {
        if shell.showProjects { return ("AstroCat", "Library home") }
        if shell.showImport { return (catalog.frames.first?.object ?? "AstroCat", "Import") }
        let object = catalog.frames.first?.object ?? "No project"
        return (
            object,
            "\(catalog.sessions.count) sessions · \(catalog.frames.count) frames")
    }
}

struct Segmented: View {
    let items: [String]
    @Binding var index: Int
    var height: CGFloat = 20
    var font: Font = Face.secondary
    var padding: CGFloat = Space.lg

    @Environment(\.tokens) private var t

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, label in
                Button { index = i } label: {
                    Text(label)
                        .font(font)
                        .foregroundStyle(i == index ? t.selT : t.t2)
                        .padding(.horizontal, padding)
                        .frame(height: height)
                        .background(i == index ? t.sel : .clear)
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control).stroke(t.line2, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

struct SubToolbar: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var catalog: Catalog
    @Environment(\.tokens) private var t

    var body: some View {
        HStack(spacing: Space.md) {
            if shell.showProjects || shell.showImport {
                Text(shell.showProjects ? "Projects" : "Import")
                    .font(Face.screenTitle)
                    .tracking(Face.screenTitleTracking)
                    .foregroundStyle(t.t1)
                Spacer()
            } else if shell.module == .library {
                Divider().frame(height: 14).overlay(t.line2)

                Segmented(
                    items: LibraryView.allCases.map(\.rawValue),
                    index: Binding(
                        get: { LibraryView.allCases.firstIndex(of: shell.libraryView) ?? 0 },
                        set: { shell.libraryView = LibraryView.allCases[$0] }))

                if shell.libraryView == .trace {
                    Segmented(
                        items: TraceMetric.allCases.map(\.rawValue),
                        index: Binding(
                            get: { TraceMetric.allCases.firstIndex(of: shell.metric) ?? 0 },
                            set: { shell.metric = TraceMetric.allCases[$0] }))
                }

                act("Select all") {
                    shell.namedSelection = nil
                    shell.rankSelection = 0
                    shell.cutWorst = 0
                    shell.anchor = 0
                    shell.cursor = max(0, catalog.current.count - 1)
                }

                Spacer()

                act("Keep \(selectionCount)", badge: "A", tint: t.q5) { apply(false) }
                act("Reject \(selectionCount)", badge: "X", tint: t.q1) { apply(true) }

                Text("Cut worst").font(Face.secondary).foregroundStyle(t.t3)
                // Updates through the binding, not onEditingChanged, so the
                // selection tracks the drag and you can see where to stop.
                Slider(
                    value: Binding(
                        get: { shell.cutWorst },
                        set: { v in
                            shell.cutWorst = v
                            shell.namedSelection = nil
                            shell.anchor = nil
                            shell.rankSelection = Int(
                                (v * Float(catalog.current.count)).rounded())
                        }),
                    in: 0...1)
                    .controlSize(.small)
                    .frame(width: 90)
                Text(String(format: "%.0f%%", shell.cutWorst * 100))
                    .font(Face.mono(11)).foregroundStyle(t.t2).frame(width: 34)
                Text("\(shell.rankSelection) of \(catalog.current.count)")
                    .font(Face.mono(11)).foregroundStyle(t.t3).frame(width: 82)


                    .buttonStyle(.plain)
                    .font(Face.body)
                    .foregroundStyle(t.t1)
                    .padding(.horizontal, Space.md)
                    .frame(height: 20)
                    .background(t.s3)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .stroke(t.line2, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                act(catalog.dirty ? "Save •" : "Saved", tint: catalog.dirty ? t.q3 : t.t3) {
                    catalog.save()
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: Metric.subToolbar)
        .background(t.s1)
    }


    private var selectionCount: Int {
        librarySelection(catalog, shell).count
    }

    private func apply(_ rejected: Bool) {
        for id in librarySelection(catalog, shell) {
            catalog.setRejected(id, rejected)
        }
    }

    private func act(
        _ label: String, badge: String? = nil, tint: Color? = nil,
        _ run: @escaping () -> Void
    ) -> some View {
        Button(action: run) {
            HStack(spacing: Space.xs) {
                Text(label).font(Face.body).foregroundStyle(tint ?? t.t2)
                if let badge {
                    Text(badge).font(Face.mono(10)).foregroundStyle(tint ?? t.t3)
                        .padding(.horizontal, 4).frame(height: 14)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.swatch)
                                .stroke(t.line2, lineWidth: 0.5))
                }
            }
            .padding(.horizontal, Space.md).frame(height: 20)
            .background(t.s2)
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .stroke(t.line2, lineWidth: 0.5))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
    }

    private func unusedCounter(_ label: String, _ key: String, _ colour: Color) -> some View {
        HStack(spacing: Space.xs) {
            Text(label).font(Face.body).foregroundStyle(t.t2)
            Text(key)
                .font(Face.mono(10))
                .foregroundStyle(colour)
                .padding(.horizontal, 4)
                .frame(height: 14)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.swatch)
                        .stroke(t.line2, lineWidth: 0.5))
        }
    }
}

struct StatusBar: View {
    @ObservedObject var shell: ShellModel
    @ObservedObject var catalog: Catalog
    @Environment(\.tokens) private var t

    var body: some View {
        HStack(spacing: Space.lg) {
            if catalog.sessions.indices.contains(catalog.sessionIndex) {
                let s = catalog.sessions[catalog.sessionIndex]
                Text(catalog.frames.first?.object ?? "—")
                    .font(Face.mono(11)).foregroundStyle(t.t2)
                Text(s.night).font(Face.mono(11)).foregroundStyle(t.t3)
                Text("\(s.kept) of \(s.count) kept")
                    .font(Face.mono(11)).foregroundStyle(t.t3)
                Text(String(format: "%.1f h integration", Double(s.kept) * Double(s.exptime) / 3600))
                    .font(Face.mono(11)).foregroundStyle(t.t3)
            } else {
                Text("No catalog").font(Face.mono(11)).foregroundStyle(t.t3)
            }

            Spacer()

            Text("\(catalog.frames.count) frames · \(catalog.sessions.count) sessions")
                .font(Face.mono(11)).foregroundStyle(t.t3)
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: Metric.statusBar)
        .background(t.s1)
    }
}

struct PlaceholderModule: View {
    let module: Module
    @Environment(\.tokens) private var t

    var body: some View {
        HStack(spacing: 0) {
            if let w = module.sidebarWidth {
                VStack { Spacer() }
                    .frame(width: w)
                    .background(t.s1)
                Divider().overlay(t.line)
            }

            VStack(spacing: Space.md) {
                Spacer()
                Text(module.label)
                    .font(Face.document)
                    .tracking(Face.documentTracking)
                    .foregroundStyle(t.t3)
                Text("Not built yet").font(Face.body).foregroundStyle(t.t4)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(t.well)

            Divider().overlay(t.line)

            VStack { Spacer() }
                .frame(width: module.inspectorWidth)
                .background(t.s1)
        }
    }
}
