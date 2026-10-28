import SwiftUI

// Short notices that confirm an action where it happened: below the photo, or at the top of the LUT box. The status
// bar still says the same; a notice is for the moment you are looking at the photo, not at the bar. Every kind can
// be switched off in Settings ▸ Notices.

enum NoticePlace { case picture, lut }

enum NoticeKind: String, CaseIterable, Identifiable {
    // below the photo
    case export, copyPhoto, batchExport, rating, label, moveRejected, undoRedo
    case autoExposure, whiteBalance, copyPaste, lookStep, filter, overlay, foldersRefreshed
    // in the LUT box
    case lookSaved, lutsLoaded, favourite, lutInput, lookMode

    var id: String { rawValue }

    var place: NoticePlace {
        switch self {
        case .lookSaved, .lutsLoaded, .favourite, .lutInput, .lookMode: .lut
        default: .picture
        }
    }

    /// What the switch in Settings is called.
    var title: String {
        switch self {
        case .export: "Export of this photo (right-click, Export As…)"
        case .copyPhoto: "Edited photo copied to the clipboard"
        case .batchExport: "Batch export finished"
        case .rating: "Rating and reject"
        case .label: "Colour label"
        case .moveRejected: "Moved to _Rejected"
        case .undoRedo: "Undo and redo"
        case .autoExposure: "Auto exposure result"
        case .whiteBalance: "White balance changes (W, Auto WB, Copy WB)"
        case .copyPaste: "Settings copied / pasted (⌘C / ⌘V)"
        case .lookStep: "Look switched with [ ] { }"
        case .filter: "Filter on / off (V)"
        case .overlay: "Clipping overlays on / off (O / U)"
        case .foldersRefreshed: "Folders refreshed"
        case .lookSaved: "Look saved to a photo (double-click)"
        case .lutsLoaded: "LUTs loaded, new LUTs found"
        case .favourite: "Favourite look added / removed"
        case .lutInput: "LUT input space changed"
        case .lookMode: "Preview / Apply / Per photo switched"
        }
    }
}

struct Notice: Equatable {
    let text: String
    let icon: String
    let serial: Int
}

/// Its own observable, so a notice redraws only the two places that show one.
@MainActor
final class NoticeCenter: ObservableObject {
    @Published private(set) var picture: Notice?
    @Published private(set) var lut: Notice?
    @Published var off: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "noticesOff") ?? []) {
        didSet { UserDefaults.standard.set(Array(off).sorted(), forKey: "noticesOff") }
    }
    private var serial = 0

    func isOn(_ k: NoticeKind) -> Bool { !off.contains(k.rawValue) }

    func post(_ kind: NoticeKind, _ text: String, icon: String) {
        guard isOn(kind), !text.isEmpty else { return }
        serial += 1
        let n = Notice(text: text, icon: icon, serial: serial)
        withAnimation(.easeOut(duration: 0.15)) {
            if kind.place == .picture { picture = n } else { lut = n }
        }
        let place = kind.place, s = serial
        let hold = text.count > 60 ? 3.2 : 2.2                       // longer ones get read for longer
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard let self else { return }
            withAnimation(.easeIn(duration: 0.3)) {
                if place == .picture, self.picture?.serial == s { self.picture = nil }
                if place == .lut, self.lut?.serial == s { self.lut = nil }
            }
        }
    }
}

/// The capsule a notice is shown in.
struct NoticeView: View {
    @ObservedObject var center: NoticeCenter
    let place: NoticePlace

    var body: some View {
        if let n = place == .picture ? center.picture : center.lut {
            Label(n.text, systemImage: n.icon)
                .font(.system(size: place == .picture ? 12 : 11, weight: .medium))
                .lineLimit(2).truncationMode(.middle).multilineTextAlignment(.center)
                .padding(.horizontal, 12).padding(.vertical, 6)
                .glassCapsule()
                .padding(8)
                .transition(.opacity.combined(with: .move(edge: place == .picture ? .bottom : .top)))
                .allowsHitTesting(false)
                .id(n.serial)
        }
    }
}

/// Settings ▸ Notices: one switch per kind, grouped by where it shows.
struct NoticeSettings: View {
    @ObservedObject var center: NoticeCenter

    var body: some View {
        Section("Notices below the photo") { toggles(.picture) }
        Section("Notices in the LUT box") { toggles(.lut) }
    }

    @ViewBuilder private func toggles(_ place: NoticePlace) -> some View {
        ForEach(NoticeKind.allCases.filter { $0.place == place }) { k in
            Toggle(k.title, isOn: Binding(get: { center.isOn(k) },
                                          set: { on in if on { center.off.remove(k.rawValue) } else { center.off.insert(k.rawValue) } }))
        }
    }
}
