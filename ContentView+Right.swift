import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Right column panels: histogram, stats, develop, white balance, LUT.

extension ContentView {
    // MARK: right column

    var histogramView: some View {
        Canvas { ctx, size in
            let plot = CGRect(x: 4, y: 16, width: size.width - 8, height: size.height - 20)
            let colors: [Color] = [.red, .green, .blue]
            func x(for ev: Float) -> CGFloat {
                plot.minX + plot.width * CGFloat((ev - HistogramData.evMin) / (HistogramData.evMax - HistogramData.evMin))
            }
            for (ev, label) in [(HistogramData.underEV, "UE\(Int(HistogramData.underEV))"), (0, "EV0")] {
                var line = Path(); line.move(to: CGPoint(x: x(for: ev), y: plot.minY)); line.addLine(to: CGPoint(x: x(for: ev), y: plot.maxY))
                ctx.stroke(line, with: .color(.gray.opacity(0.7)), lineWidth: 1)
                ctx.draw(Text(label).font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: x(for: ev), y: 7))
            }
            ctx.draw(Text("-9").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: plot.minX + 6, y: 7))
            ctx.draw(Text("+3").font(.system(size: 9)).foregroundColor(.secondary), at: CGPoint(x: plot.maxX - 8, y: 7))
            guard let h = m.hist else { return }
            for c in 0..<3 {
                var path = Path()
                for i in 0..<HistogramData.bins {
                    let px = plot.minX + plot.width * CGFloat(i) / CGFloat(HistogramData.bins - 1)
                    let py = plot.maxY - plot.height * CGFloat(h.curves[c][i])
                    if i == 0 { path.move(to: CGPoint(x: px, y: py)) } else { path.addLine(to: CGPoint(x: px, y: py)) }
                }
                ctx.stroke(path, with: .color(colors[c].opacity(0.9)), lineWidth: 1.2)
            }
        }
        .background(Color.black.opacity(0.35))
        .padding(4)
    }

    var statsView: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text(m.hist?.circleMasked == true ? "lens disc" : "").font(.system(size: 9)).foregroundStyle(.secondary)
                Text("UnExp").foregroundStyle(.secondary)
                Text("OvExp").foregroundStyle(.secondary)
            }
            ForEach(0..<3, id: \.self) { c in
                let color: Color = [Color.red, .green, .blue][c]
                GridRow {
                    Text(["R", "G", "B"][c]).foregroundStyle(color).bold()
                    Text(m.hist.map { String(format: "%.1f%%", $0.under[c]) } ?? "–").foregroundStyle(color)
                    Text(m.hist.map { String(format: "%.3f%%", $0.over[c]) } ?? "–").foregroundStyle(color).bold()
                }
            }
        }
        .font(.system(size: 12).monospacedDigit())
        .frame(maxWidth: .infinity)
        .padding(4)
    }

    // MARK: white balance panel

    var whiteBalancePanel: some View {
        PanelBox("White Balance", panel: .whiteBalance, onClose: { m.toggle(.whiteBalance) }) {
            VStack(alignment: .leading, spacing: 8) {
                // Each row falls back to a narrower arrangement in a narrow column instead of overflowing it.
                ViewThatFits(in: .horizontal) {
                    HStack { wbPresetMenu; pickNeutral(label: true); Spacer(); wbAsShot }
                    HStack { wbPresetMenu; pickNeutral(label: false); Spacer(); wbAsShot }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { wbTempField(70); wbTintField(56) }
                    HStack(spacing: 4) { wbTempField(58); wbTintField(46) }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { wbAsShotText(prefix: true); Spacer(); copyWBMenu }
                    HStack { wbAsShotText(prefix: false); Spacer(); copyWBMenu }
                }
            }
            .padding(8)
        }
    }

    var wbPresetMenu: some View {
        Menu(m.wbIsCustom ? "Custom" : "As shot") {
            ForEach(WBPreset.all) { p in Button(p.name) { m.applyWBPreset(p) } }
        }
        .fixedSize()
    }

    func pickNeutral(label: Bool) -> some View {
        Button { m.pickingWB.toggle() } label: {
            if label { Label("Pick neutral", systemImage: "eyedropper") } else { Image(systemName: "eyedropper") }
        }
        .controlSize(.small).fixedSize()
        .tint(m.pickingWB ? .accentColor : nil)
        .help("Pick neutral: click a grey spot in the picture")
    }

    var wbAsShot: some View {
        Button("As shot") { m.resetWB(); m.developChanged() }.controlSize(.small).fixedSize().disabled(!m.wbIsCustom)
    }

    func wbTempField(_ w: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("Temp").font(.caption).fixedSize()
            TextField("K", value: Binding(get: { m.temperature.rounded() }, set: { m.temperature = min(max($0, 2000), 12000); m.developChanged() }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: w)
            Text("K").font(.caption)
        }
    }

    func wbTintField(_ w: CGFloat) -> some View {
        HStack(spacing: 4) {
            Text("Tint").font(.caption).fixedSize()
            TextField("tint", value: Binding(get: { m.tint.rounded() }, set: { m.tint = min(max($0, -150), 150); m.developChanged() }), format: .number)
                .textFieldStyle(.roundedBorder).frame(width: w)
        }
    }

    @ViewBuilder func wbAsShotText(prefix: Bool) -> some View {
        if let a = m.asShot {
            Text(String(format: prefix ? "As shot: %.0f K / %+.0f" : "%.0f K / %+.0f", a.temp, a.tint))
                .font(.caption).foregroundStyle(.secondary).fixedSize().help("As-shot white balance")
        }
    }

    var copyWBMenu: some View {
        Menu("Copy WB to…") {
            Button("Selection (\(m.selection.count))") { copyWB(to: m.actionTargets()) }.disabled(!m.hasGroup)
            Button("Every shown photo (\(m.files.count))") { copyWB(to: m.files) }
        }
        .fixedSize().controlSize(.small).disabled(m.current == nil)
    }

    func copyWB(to urls: [URL]) { m.copyWhiteBalance(to: urls) }

    // MARK: LUT panel (takes the slot FastRawViewer gives Sort & Filter)

    var lutPanel: some View {
        PanelBox("LUT", panel: .looks, onClose: { m.toggle(.looks) }, trailing: { HStack(spacing: 6) { lookModeSwitch; lutMenu } }) {
            ScrollView {
                // Adapts to the column width: as many cells per row as fit (thumbnail size from the gear menu)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: m.lutColumns == 2 ? 160 : 104), spacing: 6)], spacing: 8) {
                    ForEach(m.visibleLooks) { look in lookCell(look) }
                }
                .padding(8)
                Text(lutFooter).font(.caption2).foregroundStyle(.secondary).padding(.bottom, 6)
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in dropFiles(providers, intoLUTs: true) }
            .overlay(alignment: .top) {
                if let n = m.lutNotice {
                    Label(n, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassCapsule()
                        .padding(.top, 6).padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    var lutFooter: String {
        var s = "\(m.batchPPs.count) ticked for export"
        if let f = m.lutFolder { s += " · \(m.luts.count) LUT(s) from \(f.lastPathComponent)" }
        else { s += " · drop a folder of .cube LUTs here" }
        return s
    }

    /// Preview / Apply / Per photo, in the header next to the gear: tiny compressed capitals, so it costs no row.
    var lookModeSwitch: some View {
        HStack(spacing: 1) {
            ForEach(LookMode.allCases) { mode in
                let on = m.lookMode == mode
                Text(mode.title.uppercased())
                    .font(.system(size: 9, weight: .bold)).fontWidth(.compressed).tracking(0.6)
                    .foregroundStyle(on ? Color.white : Color.secondary)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 3).fill(on ? Color.accentColor : .clear))
                    .contentShape(Rectangle())
                    .onTapGesture { m.lookMode = mode }
                    .help(mode.help)
            }
        }
        .padding(1)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
        .fixedSize()
    }

    var lutMenu: some View {
        Menu {
            Picker("Thumbnails", selection: $m.lutColumns) {
                Text("Large").tag(2)
                Text("Small").tag(3)
            }
            Toggle("Favourites only", isOn: $m.favoriteLooksOnly)
            Divider()
            Button("Choose LUT folder…") { m.chooseLUTFolder() }
            Menu("Recent LUT folders") {
                ForEach(m.recentLUTFolders, id: \.self) { u in
                    Button(u.deletingLastPathComponent().lastPathComponent + "/" + u.lastPathComponent) { m.loadLUTFolder(u, remember: true) }
                }
            }
            .disabled(m.recentLUTFolders.isEmpty)
            if m.lutFolder != nil { Button("Clear LUTs") { m.clearLUTs() } }
            Divider()
            Text("Tick looks to export:")
            Button("Favourite looks") { m.tickFavoriteLooks() }
            Button("All looks") { m.batchPPs = Set(m.looks.map(\.id)) }
            Button("PP1–PP10 only") { m.batchPPs = Set(1...10) }
            Button("None") { m.batchPPs = [] }
        } label: { Image(systemName: "gearshape") }
        .menuStyle(.borderlessButton).fixedSize()
    }

    func lookCell(_ look: PPLook) -> some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topLeading) {
                Color.gray.opacity(0.2)
                    .aspectRatio(1.5, contentMode: .fit)
                    // the filled thumbnail overflows its frame; clipped() hides that but does not stop it taking
                    // clicks, so a tall photo's overflow used to select the cell below or above
                    .overlay { if let t = m.thumbs[look.id] { Image(nsImage: t).resizable().scaledToFill().allowsHitTesting(false) } }
                    .clipped()
                    .contentShape(Rectangle())
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(look.id == m.ppID ? Color.accentColor : .clear, lineWidth: 3))
                Toggle("", isOn: Binding(
                    get: { m.batchPPs.contains(look.id) },
                    set: { if $0 { m.batchPPs.insert(look.id) } else { m.batchPPs.remove(look.id) } }
                ))
                .labelsHidden().padding(3)
                HStack {
                    Spacer()
                    Button { m.toggleFavoriteLook(look.id) } label: {
                        Image(systemName: m.isFavorite(look.id) ? "star.fill" : "star")
                            .foregroundStyle(m.isFavorite(look.id) ? Color.yellow : Color.white)
                            .shadow(radius: 2)
                    }
                    .buttonStyle(.plain).padding(4)
                }
            }
            Text(look.title).font(.caption2).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .top)
        }
        .contentShape(Rectangle())
        .help(look.note + "\nDouble-click: save to this photo")
        .onTapGesture { m.chooseLook(look.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded { m.applyLookToCurrent(look.id) })
    }

}
