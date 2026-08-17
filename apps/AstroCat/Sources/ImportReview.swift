import AppKit
import SwiftUI

struct ScanGroup: Identifiable {
    var id: Int
    var name: String
    var spec: String
    var reason: String
    var isMaster: Bool
    var frames: Int
    var fresh: Int
    var present: Int
    var bytes: Int64
    var span: Int64
    var gaps: Int
    var sampleFile: String
}

@MainActor
final class ImportModel: ObservableObject {
    @Published var source = ""
    @Published var project = ""
    @Published var groups: [ScanGroup] = []
    @Published var stats = AcScanStats()
    @Published var chosen: Set<Int> = []
    @Published var highlighted: Int?
    @Published var copyIntoProject = false

    func scan(_ dir: String, project: String) {
        source = dir
        self.project = project
        let n = dir.withCString { d in
            project.withCString { p in ac_scan(d, p) }
        }
        guard n >= 0 else { groups = []; return }

        var s = AcScanStats()
        _ = ac_scan_stats(&s)
        stats = s

        var out: [ScanGroup] = []
        for i in 0..<UInt32(n) {
            var g = AcGroup()
            guard ac_scan_group(i, &g) == 1 else { continue }
            out.append(
                ScanGroup(
                    id: Int(i),
                    name: str(ac_group_name(i)),
                    spec: str(ac_group_spec(i)),
                    reason: str(ac_group_reason(i)),
                    isMaster: g.kind != 0,
                    frames: Int(g.frames), fresh: Int(g.fresh), present: Int(g.present),
                    bytes: g.bytes, span: g.span, gaps: Int(g.gaps),
                    sampleFile: str(ac_group_file(i, 0))))
        }
        groups = out
        // Masters are excluded from lights and start unchecked.
        chosen = Set(out.filter { !$0.isMaster && $0.fresh > 0 }.map(\.id))
        highlighted = out.first?.id
    }

    var willImport: Int {
        groups.filter { chosen.contains($0.id) }.reduce(0) { $0 + $1.fresh }
    }

    var willSkip: Int {
        groups.reduce(0) { $0 + $1.present }
    }

    private func str(_ p: UnsafePointer<CChar>?) -> String {
        guard let p else { return "" }
        return String(cString: p)
    }
}

struct ImportModule: View {
    @ObservedObject var model: ImportModel
    @ObservedObject var catalog: Catalog
    @Environment(\.tokens) private var t

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                head
                Divider().overlay(t.line)
                statsStrip
                Divider().overlay(t.line)
                groupTable
                Divider().overlay(t.line)
                footer
            }
            .frame(maxWidth: .infinity)
            .background(t.s0)

            Divider().overlay(t.line)
            evidence.frame(width: 460, alignment: .leading).background(t.s1)
        }
    }

    private var head: some View {
        HStack(spacing: Space.md) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Import into \(URL(fileURLWithPath: model.project).lastPathComponent)")
                    .font(Face.title).foregroundStyle(t.t1)
                Text(model.source.isEmpty ? "No folder chosen" : model.source)
                    .font(Face.mono(10)).foregroundStyle(t.t3)
            }
            Spacer()
            button("Choose…") { pick() }
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 44)
    }

    private var statsStrip: some View {
        HStack(spacing: Space.h1) {
            stat("files seen", "\(model.stats.files)")
            stat("lights", "\(model.stats.lights)")
            stat("masters", "\(model.stats.masters)")
            stat("sessions", "\(model.stats.sessions)")
            stat("total size", String(format: "%.1f GB", Double(model.stats.bytes) / 1_073_741_824))
            Spacer()
            Text("grouped by object + observing night (noon rollover) + filter + exposure")
                .font(Face.secondary).foregroundStyle(t.t3)
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 52)
        .background(t.s1)
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label.uppercased())
                .font(Face.sectionHeader).tracking(Face.sectionTracking)
                .foregroundStyle(t.t3)
            Text(value).font(Face.mono(13)).foregroundStyle(t.t1)
        }
    }

    private var groupTable: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.groups) { g in
                    groupRow(g)
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func groupRow(_ g: ScanGroup) -> some View {
        let on = model.chosen.contains(g.id)
        let lit = model.highlighted == g.id
        return Button { model.highlighted = g.id } label: {
            HStack(spacing: Space.md) {
                checkbox(on: on, enabled: !g.isMaster) {
                    if on { model.chosen.remove(g.id) } else { model.chosen.insert(g.id) }
                }

                Text(g.name).font(Face.body)
                    .foregroundStyle(g.isMaster ? t.t3 : (lit ? t.selT : t.t1))
                    .frame(width: 220, alignment: .leading)

                Text(g.spec).font(Face.mono(11)).foregroundStyle(t.t2)
                    .frame(width: 90, alignment: .leading)

                if g.isMaster {
                    Text("excluded").font(Face.secondary).foregroundStyle(t.t3)
                        .padding(.horizontal, Space.sm).frame(height: 16)
                        .background(t.s3)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.swatch))
                }
                Spacer()

                num("\(g.frames)", t.t2, 60)
                num(g.fresh > 0 ? "+\(g.fresh)" : "—", g.fresh > 0 ? t.q5 : t.t4, 60)
                num(g.present > 0 ? "\(g.present)" : "—", t.t3, 60)
                num(String(format: "%.1fG", Double(g.bytes) / 1_073_741_824), t.t3, 60)
                num(g.span > 0 ? "\(g.span / 60)m" : "—", t.t3, 50)
            }
            .padding(.horizontal, Metric.panelPad)
            .frame(height: Metric.rowHeight)
            .background(lit ? t.sel : .clear)
            .opacity(g.isMaster ? 0.55 : 1)
            .overlay(alignment: .bottom) { Rectangle().fill(t.line).frame(height: 0.5) }
        }
        .buttonStyle(.plain)
    }

    private func num(_ s: String, _ c: Color, _ w: CGFloat) -> some View {
        Text(s).font(Face.mono(11)).foregroundStyle(c)
            .frame(width: w, alignment: .trailing)
    }

    private func checkbox(on: Bool, enabled: Bool, _ toggle: @escaping () -> Void) -> some View {
        Button(action: { if enabled { toggle() } }) {
            RoundedRectangle(cornerRadius: Radius.swatch)
                .fill(on && enabled ? t.selT : .clear)
                .frame(width: 12, height: 12)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.swatch)
                        .stroke(enabled ? t.line3 : t.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private var evidence: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let id = model.highlighted,
                    let g = model.groups.first(where: { $0.id == id })
                {
                    Text(URL(fileURLWithPath: g.sampleFile).lastPathComponent)
                        .font(Face.mono(11)).foregroundStyle(t.t3)
                    Text("Filename is not used for classification")
                        .font(Face.secondary).foregroundStyle(t.t4)
                        .padding(.bottom, Space.lg)

                    Text(g.isMaster ? "Master stack" : "Light frame")
                        .font(Face.title)
                        .foregroundStyle(g.isMaster ? t.q3 : t.q5)
                    Text(g.reason)
                        .font(Face.secondary).foregroundStyle(t.t2)
                        .padding(.bottom, Space.lg)

                    Text("FITS HEADER")
                        .font(Face.sectionHeader).tracking(Face.sectionTracking)
                        .foregroundStyle(t.t3).padding(.bottom, Space.sm)

                    ForEach(Array(headerCards(g.sampleFile).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(Face.mono(9))
                            .foregroundStyle(critical(line, master: g.isMaster) ? t.t1 : t.t3)
                            .padding(.horizontal, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(critical(line, master: g.isMaster) ? t.s4 : .clear)
                    }
                }
                Spacer()
            }
            .padding(Metric.panelPad)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headerCards(_ path: String) -> [String] {
        guard !path.isEmpty, let p = path.withCString({ ac_header_text($0) }) else { return [] }
        return String(cString: p).split(separator: "\n").map(String.init)
    }

    private func critical(_ line: String, master: Bool) -> Bool {
        let keys = master
            ? ["NAXIS3", "BAYERPAT", "STACKCNT"]
            : ["DATE-OBS", "OBJECT", "FILTER", "EXPTIME"]
        return keys.contains { line.hasPrefix($0) }
    }

    private var footer: some View {
        HStack(spacing: Space.lg) {
            Text("\(model.willImport) frames will be imported · \(model.willSkip) already held")
                .font(Face.body).foregroundStyle(t.t2)
            Toggle("Copy files into project", isOn: $model.copyIntoProject)
                .font(Face.body).foregroundStyle(t.t3).toggleStyle(.checkbox)
            Spacer()
            button("Cancel") {}
            button("Import \(model.willImport)", primary: true) {
                catalog.build(model.source)
            }
        }
        .padding(.horizontal, Metric.panelPad)
        .frame(height: 44)
        .background(t.s1)
    }

    private func button(_ label: String, primary: Bool = false, _ action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Text(label).font(Face.body)
                .foregroundStyle(primary ? t.selT : t.t1)
                .padding(.horizontal, Space.lg).frame(height: 22)
                .background(primary ? t.sel : t.s3)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.control)
                        .stroke(primary ? t.selLine : t.line2, lineWidth: 0.5))
                .clipShape(RoundedRectangle(cornerRadius: Radius.control))
        }
        .buttonStyle(.plain)
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            model.scan(url.path, project: model.project.isEmpty ? url.path : model.project)
        }
    }
}
