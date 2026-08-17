import AppKit
import SwiftUI

struct Project: Identifiable {
    var id: String { path }
    var path: String
    var name: String
    var exists: Bool
    var sessions: Int
    var frames: Int
    var kept: Int
    var bytes: Int64
    var lastNight: Int64
    var opened: Date
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published var projects: [Project] = []
    @Published var selected: String?

    private var registry: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AstroCat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("projects.tsv")
    }

    func load(seeding seed: String?) {
        var paths = (try? String(contentsOf: registry, encoding: .utf8))
            .map { $0.split(separator: "\n").map(String.init) } ?? []
        if let seed, !paths.contains(seed) { paths.append(seed) }
        projects = paths.compactMap(summary)
        if selected == nil { selected = projects.first?.path }
        save(paths)
    }

    func add(_ path: String) {
        guard !projects.contains(where: { $0.path == path }) else { return }
        if let p = summary(path) {
            projects.append(p)
            selected = path
            save(projects.map(\.path))
        }
    }

    private func save(_ paths: [String]) {
        try? paths.joined(separator: "\n").write(to: registry, atomically: true, encoding: .utf8)
    }

    private func summary(_ path: String) -> Project? {
        var p = AcProject()
        guard path.withCString({ ac_project_summary($0, &p) }) == 1 else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return Project(
            path: path,
            name: URL(fileURLWithPath: path).lastPathComponent,
            exists: p.exists != 0,
            sessions: Int(p.sessions), frames: Int(p.frames), kept: Int(p.kept),
            bytes: p.bytes, lastNight: p.last_night,
            opened: (attrs?[.modificationDate] as? Date) ?? .distantPast)
    }
}

private func gb(_ b: Int64) -> String {
    String(format: "%.1f GB", Double(b) / 1_073_741_824)
}

private func nightLabel(_ second: Int64) -> String {
    guard second > 0 else { return "—" }
    let days = second / 86400
    let y = days / 372
    let m = (days % 372) / 31
    let d = days % 31
    return String(format: "%04d-%02d-%02d", y, m, d)
}

struct HomeModule: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var catalog: Catalog
    @ObservedObject var shell: ShellModel
    @Environment(\.tokens) private var t

    private var project: Project? {
        store.projects.first { $0.path == store.selected }
    }

    var body: some View {
        HStack(spacing: 0) {
            table
            Divider().overlay(t.line)
            rail.frame(width: 320, alignment: .leading).background(t.s1)
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                col("Target", 190, .leading)
                col("Sessions", 70, .trailing)
                col("Frames", 70, .trailing)
                col("Kept", 70, .trailing)
                col("Size", 90, .trailing)
                col("Last night", 110, .trailing)
                col("Location", nil, .leading)
            }
            .frame(height: 22)
            .background(t.s2)

            Divider().overlay(t.line)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.projects) { p in
                        row(p)
                    }
                }
            }
            Spacer(minLength: 0)

            HStack {
                Button("Add project…") { pick() }
                    .buttonStyle(.plain).font(Face.body).foregroundStyle(t.t1)
                    .padding(.horizontal, Space.md).frame(height: 22)
                    .background(t.s3)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control))
                Spacer()
            }
            .padding(Metric.panelPad)
        }
        .frame(maxWidth: .infinity)
        .background(t.s0)
    }

    private func row(_ p: Project) -> some View {
        let on = p.path == store.selected
        let tint = p.exists ? t.q5 : t.q2
        return Button { store.selected = p.path } label: {
            HStack(spacing: 0) {
                HStack(spacing: Space.sm) {
                    Circle().fill(tint).frame(width: 6, height: 6)
                    Text(p.name).font(Face.body).foregroundStyle(on ? t.selT : t.t1)
                    Spacer()
                }
                .frame(width: 190, alignment: .leading)

                cell("\(p.sessions)", 70)
                cell("\(p.frames)", 70)
                cell("\(p.kept)", 70)
                cell(gb(p.bytes), 90)
                cell(nightLabel(p.lastNight), 110)

                Text(p.path)
                    .font(Face.mono(10))
                    .foregroundStyle(p.exists ? t.t3 : t.q2)
                    .lineLimit(1).truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, Space.md)
            .frame(height: Metric.rowHeight)
            .background(on ? t.sel : .clear)
            .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 0.5) }
        }
        .buttonStyle(.plain)
    }

    private func col(_ s: String, _ w: CGFloat?, _ a: Alignment) -> some View {
        Text(s.uppercased())
            .font(Face.sectionHeader).tracking(Face.sectionTracking)
            .foregroundStyle(t.t3)
            .padding(.horizontal, Space.md)
            .frame(width: w, alignment: a)
            .frame(maxWidth: w == nil ? .infinity : nil, alignment: a)
    }

    private func cell(_ s: String, _ w: CGFloat) -> some View {
        Text(s).font(Face.mono(11)).foregroundStyle(t.t2)
            .padding(.horizontal, Space.md)
            .frame(width: w, alignment: .trailing)
    }

    private var rail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                RoundedRectangle(cornerRadius: Radius.panel)
                    .fill(t.img).frame(height: 150)

                if let p = project {
                    Text(p.name).font(Face.title).foregroundStyle(t.t1)
                        .padding(.top, Space.lg)
                    Text("\(p.sessions) sessions · \(p.frames) frames · \(p.kept) kept · \(gb(p.bytes))")
                        .font(Face.secondary).foregroundStyle(t.t2)

                    if !p.exists {
                        VStack(alignment: .leading, spacing: Space.sm) {
                            Text("Volume not found")
                                .font(Face.body).foregroundStyle(t.q2)
                            HStack(spacing: Space.sm) {
                                small("Locate volume…") {}
                                small("Work offline") {}
                            }
                        }
                        .padding(Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.panel)
                                .stroke(t.q2, lineWidth: 0.5))
                        .padding(.top, Space.lg)
                    }

                    header("Sessions").padding(.top, Space.xl)
                    ForEach(catalog.sessions) { s in
                        HStack {
                            Text(s.night).font(Face.body).foregroundStyle(t.t2)
                            Spacer()
                            Text("\(s.kept)/\(s.count)")
                                .font(Face.mono(11)).foregroundStyle(t.t3)
                        }
                        .frame(height: 20)
                    }

                    header("On disk").padding(.top, Space.xl)
                    fact("Catalog", "\(p.path)/.astrocat")
                    fact("Frames", "referenced in place")

                    HStack(spacing: Space.sm) {
                        small("Open") {
                            catalog.open(p.path)
                            shell.module = .library
                        }
                        small("Rename") {}
                        small("Archive") {}
                        small("Reveal") {
                            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p.path)
                        }
                    }
                    .padding(.top, Space.xl)
                }
                Spacer()
            }
            .padding(Metric.panelPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ s: String) -> some View {
        Text(s.uppercased()).font(Face.sectionHeader).tracking(Face.sectionTracking)
            .foregroundStyle(t.t3).padding(.bottom, Space.sm)
    }

    private func fact(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(Face.secondary).foregroundStyle(t.t3)
            Text(v).font(Face.mono(10)).foregroundStyle(t.t2)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.bottom, Space.sm)
    }

    private func small(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(Face.secondary).foregroundStyle(t.t1)
                .padding(.horizontal, Space.md).frame(height: 20)
                .background(t.s3)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(t.line2, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            store.add(url.path)
        }
    }
}
