import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// Sort & Filter panel.

extension ContentView {
    // MARK: Sort & Filter panel (FastRawViewer 2: collapsible groups of tick rows with counts)

    /// A group header that folds its rows (remembered).
    @ViewBuilder func filterGroup<Rows: View>(_ title: String, id: String, @ViewBuilder rows: () -> Rows) -> some View {
        let folded = m.fpCollapsed.contains(id)
        VStack(alignment: .leading, spacing: 0) {
            Button { m.toggleFilterGroup(id) } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(folded ? 0 : 90))
                    Text(title).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary).frame(height: 20)
            .help(folded ? "Show this group" : "Fold this group")
            if !folded { rows() }
        }
    }

    /// One row: tick box, optional colour dot, title, count (nn/mm; italic while metadata is still being read).
    func filterRow(_ title: String, count: RowCount?, on: Bool, italic: Bool = false, dot: Color? = nil,
                   tickable: Bool = true, enabled: Bool = true, help: String? = nil, action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if tickable {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Color.accentColor : .secondary)
                }
                if let dot { Circle().fill(dot).frame(width: 8, height: 8) }
                Text(title).lineLimit(1)
                Spacer(minLength: 6)
                Text(count?.text ?? "0").monospacedDigit().foregroundStyle(.secondary)
                    .font(italic ? .system(size: 11).italic() : .system(size: 11))
            }
            .font(.system(size: 11))
            .frame(height: 18)
            .padding(.leading, 14).padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!tickable || !enabled)
        .opacity(enabled ? 1 : 0.5)
        .help(help ?? (tickable ? "Tick to show only these photos; tick more rows to widen, untick all to show everything. Shown / total" : "Shown / total"))
    }

    /// FRV gear options: zero rows hide (when off) only once all metadata is read; a ticked row never hides.
    func rowVisible(_ c: RowCount?, on: Bool, complete: Bool) -> Bool {
        (c?.total ?? 0) > 0 || m.fpShowZeros || !complete || on
    }

    /// FRV "Hide groups with only one value": everything falls in one row, nothing ticked, metadata complete.
    func groupHidden<K>(_ d: [K: RowCount], ticked: Bool, complete: Bool) -> Bool {
        m.fpHideSingle && complete && !ticked && d.values.filter { $0.total > 0 }.count <= 1
    }

    func toggled<T: Hashable>(_ set: Set<T>, _ v: T) -> Set<T> {
        var s = set
        if s.contains(v) { s.remove(v) } else { s.insert(v) }
        return s
    }

    var filterHeader: some View {
        HStack(spacing: 8) {
            HoverOverflow(active: m.fpNameField || !m.filter.name.isEmpty || m.filter.reverse) { filterTools }
            Toggle("", isOn: $m.filter.enabled).toggleStyle(.switch).controlSize(.mini).labelsHidden().help("Filter on / off (V)")
        }
        .foregroundStyle(.secondary)
    }

    /// Name filter, sort, refresh and options: tucked behind ⋯ so the panel title keeps its room.
    @ViewBuilder var filterTools: some View {
            Button { m.fpNameField.toggle() } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(m.fpNameField || !m.filter.name.isEmpty ? Color.accentColor : .secondary)
                .help("Filter by name")
            Menu {
                Picker("Sort by", selection: $m.filter.sort) {
                    ForEach(SortKey.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Toggle("Reverse order", isOn: $m.filter.reverse)
            } label: { Image(systemName: "arrow.up.arrow.down") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Sort")
            Menu {
                Button("Re-read current folder") { m.rereadFolder() }
                Button("Forced full metadata read") { m.forceFullMetadataRead() }
            } label: { Image(systemName: "arrow.clockwise") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Refresh")
            Menu {
                Toggle("Show File/Metadata status", isOn: $m.fpShowStatus)
                Toggle("Show Selected files", isOn: $m.fpShowSelected)
                Toggle("Show zero values for complete fetched data", isOn: $m.fpShowZeros)
                Toggle("Hide groups with only one value", isOn: $m.fpHideSingle)
                Divider()
                Toggle("Hide rejected when no rating is ticked", isOn: $m.filter.hideRejected)
                Button("Reset filter") { m.resetFilter() }.disabled(!m.filter.hasTicks)
            } label: { Image(systemName: "gearshape") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Options")
    }

    var filterPanel: some View {
        let c = m.counts
        let complete = !c.incomplete
        let it = c.incomplete                   // italic counts while metadata is still being read
        let f = m.filter
        return PanelBox("Sort & Filter", panel: .filter, onClose: { m.toggle(.filter) }, trailing: { filterHeader }) {
            // scrolls inside the box when the column is too short; its full height sizes the box otherwise
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if m.fpNameField {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Name, or a mask like *_07*", text: $m.filter.name).textFieldStyle(.roundedBorder)
                            .onSubmit { m.mainWindow?.makeFirstResponder(nil) }
                            .help("Part of the file name, a camera or lens name, or a mask with * and ?")
                        if !f.name.isEmpty {
                            Button { m.filter.name = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Clear the name filter")
                        }
                    }
                    .font(.system(size: 11)).padding(.bottom, 2)
                }
                if m.fpShowStatus {
                    filterGroup("Files/metadata", id: "status") {
                        filterRow("Total files", count: RowCount(total: c.total, shown: m.shownPhotos.count), on: false, tickable: false)
                        filterRow("Metadata unread", count: RowCount(total: c.unread, shown: c.unread), on: false, tickable: false)
                        if m.fpShowSelected {
                            filterRow("Selected", count: RowCount(total: m.selection.count, shown: m.selection.count), on: f.selectedOnly,
                                      enabled: f.selectedOnly || !m.selection.isEmpty,
                                      help: "Show only the selected photos (⌘-click / ⇧-click in the filmstrip or grid)") {
                                m.filter.selectedOnly.toggle()
                            }
                        }
                    }
                }
                if !groupHidden(c.ratings, ticked: !f.ratings.isEmpty, complete: complete) {
                    filterGroup("XMP Rating", id: "rating") {
                        ForEach([0, 1, 2, 3, 4, 5, -1], id: \.self) { r in
                            if rowVisible(c.ratings[r], on: f.ratings.contains(r), complete: complete) {
                                filterRow(r == 0 ? "Not set" : (r < 0 ? "Rejected" : String(repeating: "★", count: r)),
                                          count: c.ratings[r], on: f.ratings.contains(r), italic: it) { m.filter.ratings = toggled(f.ratings, r) }
                            }
                        }
                    }
                }
                if !groupHidden(c.labels, ticked: !f.labels.isEmpty, complete: complete) {
                    filterGroup("XMP Label", id: "label") {
                        // the five Lightroom labels, then any other label text found in the sidecars
                        let extra = c.labels.keys.filter { $0 != "None" && !labelNames.contains($0) }.sorted()
                        ForEach(["None"] + labelNames + extra, id: \.self) { n in
                            if rowVisible(c.labels[n], on: f.labels.contains(n), complete: complete) {
                                filterRow(n == "None" ? "Not set" : n, count: c.labels[n], on: f.labels.contains(n), italic: it,
                                          dot: n == "None" ? nil : labelColor(n)) { m.filter.labels = toggled(f.labels, n) }
                            }
                        }
                    }
                }
                if !groupHidden(c.dates, ticked: !f.dates.isEmpty, complete: complete) {
                    filterGroup("EXIF timestamp", id: "date") {
                        ForEach(DateBucket.allCases) { b in
                            if rowVisible(c.dates[b], on: f.dates.contains(b), complete: complete) {
                                filterRow(b.title, count: c.dates[b], on: f.dates.contains(b), italic: it, help: m.dateRange(b)) {
                                    m.filter.dates = toggled(f.dates, b)
                                }
                            }
                        }
                    }
                }
                if !groupHidden(c.looks, ticked: !f.looks.isEmpty, complete: complete) {
                    filterGroup("Look", id: "look") {
                        ForEach(LookKind.allCases) { k in
                            if rowVisible(c.looks[k], on: f.looks.contains(k), complete: complete) {
                                filterRow(k.title, count: c.looks[k], on: f.looks.contains(k), italic: it,
                                          help: k == .lut ? "Photos whose saved look is a .cube LUT" : "Photos with a PP look, Base, or no saved look") {
                                    m.filter.looks = toggled(f.looks, k)
                                }
                            }
                        }
                    }
                }
                if !groupHidden(c.kinds, ticked: !f.kinds.isEmpty, complete: true) {
                    filterGroup("File type", id: "kind") {
                        ForEach(["ARW", "RAF", "DNG"], id: \.self) { k in
                            if rowVisible(c.kinds[k], on: f.kinds.contains(k), complete: true) {
                                filterRow(k, count: c.kinds[k], on: f.kinds.contains(k)) { m.filter.kinds = toggled(f.kinds, k) }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { m.layoutStore.setContentHeight("filter", Double($0)) }
            }
        }
    }

}
