import Foundation

// `cli --xmp-selftest`: round-trip fixtures for XMPEdit / XMPFile. Never touches real photos.

func isWellFormedForTest(_ s: String) -> Bool { XMPEdit.isWellFormed(s) }

enum XMPTests {
    static let frv = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="XMP Core 5.6.0">
       <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about=""
                xmlns:xmp="http://ns.adobe.com/xap/1.0/"
                xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/"
                xmlns:libraw="http://ns.libraw.com/librawxmp/1.0/"
                xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">
             <xmp:Rating>5</xmp:Rating>
             <xmp:MetadataDate>2026-10-25T20:44:35+01:00</xmp:MetadataDate>
             <photoshop:SidecarForExtension>ARW</photoshop:SidecarForExtension>
             <libraw:MetaDataDate>2026-10-25T20:44:35+01:00</libraw:MetaDataDate>
             <libraw:FRVS>BLE:1/0/0.75/0.40;AE:0/1/1.00/2/6400/0.00</libraw:FRVS>
             <libraw:Exposure>0.400000</libraw:Exposure>
             <libraw:WBCoeffs>
                <rdf:Seq>
                   <rdf:li>2.56941</rdf:li>
                   <rdf:li>1.00000</rdf:li>
                </rdf:Seq>
             </libraw:WBCoeffs>
             <crs:Exposure2012>0.000000</crs:Exposure2012>
             <crs:Temperature>6889</crs:Temperature>
             <crs:Tint>8</crs:Tint>
          </rdf:Description>
       </rdf:RDF>
    </x:xmpmeta>
    """
    static let lightroom = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="4"
       xmp:Label="Green"
       xmp:MetadataDate="2026-10-01T10:00:00+01:00"
       crs:Exposure2012="+0.50"/>
     </rdf:RDF>
    </x:xmpmeta>
    """
    /// A realistic Lightroom / Camera Raw sidecar: attributes on the outer description AND a nested one (crs:Look).
    static let lightroomLook = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Adobe XMP Core 7.0-c000">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about=""
        xmlns:xmp="http://ns.adobe.com/xap/1.0/"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/"
       xmp:Rating="4"
       xmp:MetadataDate="2026-10-01T10:00:00+01:00"
       crs:WhiteBalance="Custom"
       crs:Temperature="5200"
       crs:Tint="+8">
       <crs:Look>
        <rdf:Description
         crs:Version="14.0">
         <crs:Parameters>
          <rdf:Description
           crs:Version="14.0"
           crs:ProcessVersion="11.0"/>
         </crs:Parameters>
        </rdf:Description>
       </crs:Look>
      </rdf:Description>
     </rdf:RDF>
    </x:xmpmeta>
    """
    static let noRating = """
    <x:xmpmeta xmlns:x="adobe:ns:meta/">
       <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:photoshop="http://ns.adobe.com/photoshop/1.0/">
             <photoshop:SidecarForExtension>RAF</photoshop:SidecarForExtension>
          </rdf:Description>
       </rdf:RDF>
    </x:xmpmeta>
    """

    static func lines(_ s: String) -> [String] { s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }

    /// Lines present in only one of the two texts.
    static func changedLines(_ a: String, _ b: String) -> (removed: [String], added: [String]) {
        let la = lines(a), lb = lines(b)
        var cb = lb.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var removed: [String] = []
        for l in la { if let c = cb[l], c > 0 { cb[l] = c - 1 } else { removed.append(l) } }
        var ca = la.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        var added: [String] = []
        for l in lb { if let c = ca[l], c > 0 { ca[l] = c - 1 } else { added.append(l) } }
        return (removed, added)
    }

    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ cond: Bool, _ detail: String = "") {
            if !cond { ok = false }
            print(cond ? "ok  " : "FAIL", name, cond ? "" : detail)
        }
        func touched(_ lines: [String]) -> Bool {
            lines.allSatisfy { $0.contains("Rating") || $0.contains("Label") || $0.contains("MetadataDate") || $0.contains("MetaDataDate")
                || $0.contains("Exposure") || $0.contains("Temperature") || $0.contains("Tint") }
        }

        // 1. FastRawViewer element form: rating changes in place, only rating + date lines differ.
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "3")], to: frv) {
            let d = changedLines(frv, r)
            check("FRV rating 5->3 in place", XMPEdit.value(of: "xmp:Rating", in: r) == "3")
            check("FRV diff limited to rating + dates", touched(d.removed) && touched(d.added) && d.removed.count == 3, "\(d)")
            check("FRV untouched tags kept", r.contains("<libraw:Exposure>0.400000</libraw:Exposure>") && r.contains("<rdf:li>2.56941</rdf:li>"))
        } else { check("FRV edit", false, "returned nil") }

        // 2. Label: inserted with matching indentation, then cleared again.
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Label", value: "Red")], to: frv) {
            check("FRV label inserted", XMPEdit.value(of: "xmp:Label", in: r) == "Red")
            check("FRV label indent matches siblings", r.contains("\n         <xmp:Label>Red</xmp:Label>") || r.contains("\n             <xmp:Label>Red</xmp:Label>"), r)
            if let r2 = XMPEdit.apply([XMPChange(tag: "xmp:Label", value: nil)], to: r, touchDate: nil) {
                let d2 = changedLines(frv, r2)
                check("label cleared -> only the date lines differ from the original", d2.removed.count == 2 && d2.added.count == 2 && d2.removed.allSatisfy { $0.contains("ate>") } && d2.added.allSatisfy { $0.contains("ate>") && !$0.contains("Label") }, "\(d2)")
            } else { check("label clear", false) }
        } else { check("FRV label", false, "nil") }

        // 3. Lightroom attribute form.
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "1"), XMPChange(tag: "xmp:Label", value: "Blue")], to: lightroom) {
            check("LR attribute rating", XMPEdit.value(of: "xmp:Rating", in: r) == "1" && r.contains("xmp:Rating=\"1\""))
            check("LR attribute label", r.contains("xmp:Label=\"Blue\""))
            check("LR other attrs kept", r.contains("crs:Exposure2012=\"+0.50\""))
        } else { check("LR edit", false, "nil") }
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Label", value: nil)], to: lightroom, touchDate: nil) {
            check("LR attribute label removed", !r.contains("xmp:Label") && r.contains("xmp:Rating=\"4\""), r)
        } else { check("LR remove label", false, "nil") }

        // 4. Missing tag + missing namespace declaration.
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "2")], to: noRating) {
            check("insert Rating + xmlns:xmp", XMPEdit.value(of: "xmp:Rating", in: r) == "2" && r.contains("xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\""), r)
        } else { check("noRating edit", false, "nil") }

        // 5. Self-closing Description.
        let selfClosing = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\"/></rdf:RDF></x:xmpmeta>"
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "5")], to: selfClosing) {
            check("self-closing Description expanded", XMPEdit.value(of: "xmp:Rating", in: r) == "5" && XMPEdit.isWellFormed(r), r)
        } else { check("self-closing edit", false, "nil") }

        // 6. CRLF preserved.
        let crlf = frv.replacingOccurrences(of: "\n", with: "\r\n")
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Label", value: "Yellow")], to: crlf) {
            check("CRLF preserved", !r.replacingOccurrences(of: "\r\n", with: "").contains("\n") && r.contains("\r\n"))
        } else { check("CRLF edit", false, "nil") }

        // 7. Refuse malformed input.
        check("malformed refused", XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "3")], to: "<x:xmpmeta><rdf:RDF></x:xmpmeta>") == nil)
        check("empty refused", XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "3")], to: "") == nil)

        // 8. Parsing the FRV sidecar like the app does.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xmptest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let raw = tmp.appendingPathComponent("A7C09999.ARW")
        try? Data().write(to: raw)
        try? Data(frv.utf8).write(to: XMPFile.url(for: raw))
        if let sc = Sidecar.load(for: raw) {
            check("Sidecar reads libraw:Exposure 0.40", sc.exposure == 0.4, "\(String(describing: sc.exposure))")
            check("Sidecar reads WB 6889 K / +8", sc.temperature == 6889 && sc.tint == 8)
            check("Sidecar reads rating 5, no label", sc.rating == 5 && sc.label == nil)
        } else { check("Sidecar.load", false) }

        // 9. File round trip: backup made once, original restored by backup, BOM kept.
        let bomData = Data([0xEF, 0xBB, 0xBF]) + Data(frv.utf8)
        try? bomData.write(to: XMPFile.url(for: raw))
        do {
            try XMPFile.write([XMPChange(tag: "xmp:Rating", value: "2")], for: raw)
            let after = try Data(contentsOf: XMPFile.url(for: raw))
            check("BOM preserved", after.starts(with: [0xEF, 0xBB, 0xBF]))
            check("rating written to disk", Sidecar.load(for: raw)?.rating == 2)
            check("backup holds the original", (try? Data(contentsOf: XMPFile.backupURL(for: raw))) == bomData)
            try XMPFile.write([XMPChange(tag: "xmp:Rating", value: "4")], for: raw)
            check("backup not overwritten by 2nd write", (try? Data(contentsOf: XMPFile.backupURL(for: raw))) == bomData)
        } catch { check("file write", false, "\(error)") }

        // 10. Missing sidecar -> minimal one is created; read-only file -> error, not a crash.
        let raw2 = tmp.appendingPathComponent("DSCF0001.RAF")
        try? Data().write(to: raw2)
        do {
            try XMPFile.write([XMPChange(tag: "xmp:Rating", value: "5")], for: raw2)
            let s = Sidecar.load(for: raw2)
            check("sidecar created when missing", s?.rating == 5 && s?.text.contains("<photoshop:SidecarForExtension>RAF<") == true)
        } catch { check("create sidecar", false, "\(error)") }
        let locked = XMPFile.url(for: raw2)
        _ = try? FileManager.default.setAttributes([.immutable: true], ofItemAtPath: locked.path)
        var threw = false
        do { try XMPFile.write([XMPChange(tag: "xmp:Rating", value: "1")], for: raw2) } catch { threw = true }
        _ = try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: locked.path)
        check("locked sidecar -> error", threw)

        // 11. Develop settings: the app's own namespace only; FRV / Adobe properties are never touched.
        var st = PhotoState(); st.ev = 1.3; st.temp = 4500; st.tint = 3; st.hl = false; st.look = "lut:Fujifilm/A & B \"x\".cube"
        let raw3 = tmp.appendingPathComponent("A7C07777.ARW")
        try? Data().write(to: raw3)
        try? Data(frv.utf8).write(to: XMPFile.url(for: raw3))
        do {
            try XMPFile.writeDevelop(st, for: raw3)
            let sc = Sidecar.load(for: raw3)
            check("develop settings round-trip (incl. & and quotes in the look)", sc?.develop == st, "\(String(describing: sc?.develop))")
            let t = sc?.text ?? ""
            check("saved as arwexport:Exposure", XMPEdit.value(of: "arwexport:Exposure", in: t) == "+1.30")
            check("FRV libraw:Exposure NOT touched", XMPEdit.value(of: "libraw:Exposure", in: t) == "0.400000")
            check("Adobe crs:Exposure2012 NOT touched", XMPEdit.value(of: "crs:Exposure2012", in: t) == "0.000000")
            check("FRV crs:Temperature / Tint NOT touched", XMPEdit.value(of: "crs:Temperature", in: t) == "6889" && XMPEdit.value(of: "crs:Tint", in: t) == "8")
            check("rating untouched by develop save", sc?.rating == 5)
            check("result is conformant XMP", XMPEdit.validate(t).isEmpty, "\(XMPEdit.validate(t))")
            check("arwexport namespace URI ends with /", t.contains("xmlns:arwexport=\"http://ns.arwexport.app/1.0/\""))
            var back = st; back.temp = nil; back.tint = nil
            try XMPFile.writeDevelop(back, for: raw3)
            let t2 = Sidecar.load(for: raw3)?.text ?? ""
            check("as-shot WB keeps FRV's crs:Temperature (B1)", XMPEdit.value(of: "crs:Temperature", in: t2) == "6889")
            check("as-shot WB removes our arwexport:Temperature", XMPEdit.value(of: "arwexport:Temperature", in: t2) == nil && XMPEdit.value(of: "arwexport:WhiteBalance", in: t2) == "As Shot")
            let beforeBytes = try Data(contentsOf: XMPFile.url(for: raw3))
            try XMPFile.writeDevelop(back, for: raw3)
            check("saving identical settings leaves the file byte-identical", try Data(contentsOf: XMPFile.url(for: raw3)) == beforeBytes)
        } catch { check("develop write", false, "\(error)") }

        // 11b. Lightroom sidecar with a nested crs:Look: new properties land in the OUTER description (B3).
        if let r = XMPEdit.apply(DevelopXMP.changes(for: st) + [XMPChange(tag: "xmp:Label", value: "Red")], to: lightroomLook) {
            let closeLook = r.range(of: "</crs:Look>")!.upperBound
            check("arwexport + label inserted after the nested crs:Look block", (r.range(of: "<arwexport:Version>")?.lowerBound ?? r.startIndex) > closeLook && (r.range(of: "<xmp:Label>")?.lowerBound ?? r.startIndex) > closeLook, r)
            check("nested-Look result is conformant", XMPEdit.validate(r).isEmpty, "\(XMPEdit.validate(r))")
            check("Lightroom WB attributes untouched", r.contains("crs:Temperature=\"5200\"") && r.contains("crs:WhiteBalance=\"Custom\""))
            check("MetadataDate updated in the outer description", !r.contains("2026-10-01T10:00:00+01:00"))
        } else { check("nested Look edit", false, "nil") }
        // a misplaced property is caught by the validator
        let misplaced = lightroomLook.replacingOccurrences(of: "crs:ProcessVersion=\"11.0\"/>", with: "crs:ProcessVersion=\"11.0\" xmp:Label=\"Red\"/>")
        check("validator flags a property inside a nested description", XMPEdit.validate(misplaced).contains { $0.contains("nested") })

        // 11c. Self-closing and attributed element forms do not produce duplicates (B9).
        let selfClosingRating = noRating.replacingOccurrences(of: "<photoshop:SidecarForExtension>RAF</photoshop:SidecarForExtension>",
                                                              with: "<photoshop:SidecarForExtension>RAF</photoshop:SidecarForExtension>\n         <xmp:Rating/>")
            .replacingOccurrences(of: "xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\"", with: "xmlns:photoshop=\"http://ns.adobe.com/photoshop/1.0/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"")
        if let r = XMPEdit.apply([XMPChange(tag: "xmp:Rating", value: "3")], to: selfClosingRating) {
            check("<xmp:Rating/> replaced, not duplicated", r.components(separatedBy: "xmp:Rating").count - 1 == 2 && XMPEdit.value(of: "xmp:Rating", in: r) == "3", r)
        } else { check("self-closing rating edit", false, "nil") }

        // 11d. Concurrent writers through the serial queue never lose a property (B2).
        let raw4 = tmp.appendingPathComponent("A7C04444.ARW")
        try? Data().write(to: raw4)
        try? Data(frv.utf8).write(to: XMPFile.url(for: raw4))
        DispatchQueue.concurrentPerform(iterations: 120) { i in
            SidecarWriter.shared.runSync {
                if i % 2 == 0 { try? XMPFile.write([XMPChange(tag: "xmp:Rating", value: String(i % 6))], for: raw4) }
                else { var s = PhotoState(); s.ev = Float(i) / 10; try? XMPFile.writeDevelop(s, for: raw4) }
            }
        }
        SidecarWriter.shared.drain()
        let final = Sidecar.load(for: raw4)
        check("120 concurrent writes: file valid, rating and develop settings both present",
              final != nil && XMPEdit.validate(final!.text).isEmpty && final!.develop != nil && (0...5).contains(final!.rating), "\(String(describing: final?.rating)) \(String(describing: final?.develop))")

        // 11e. exiftool-style sidecar: one top-level rdf:Description per namespace (prefixes declared per block).
        let multi = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:exif="http://ns.adobe.com/exif/1.0/">
           <exif:ColorSpace>1</exif:ColorSpace>
          </rdf:Description>
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
           <xmp:Rating>3</xmp:Rating>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        if let r = XMPEdit.apply(DevelopXMP.changes(for: st) + [XMPChange(tag: "xmp:Rating", value: "5"), XMPChange(tag: "xmp:Label", value: "Blue")], to: multi) {
            check("multi-block sidecar: edit accepted and conformant", XMPEdit.validate(r).isEmpty && isWellFormedForTest(r), "\(XMPEdit.validate(r))\n\(r)")
            check("multi-block: existing rating replaced in its own block", XMPEdit.value(of: "xmp:Rating", in: r) == "5")
            check("multi-block: develop settings readable", DevelopXMP.state(from: r)?.ev == st.ev)
        } else { check("multi-block edit", false, "nil (refused)") }

        // 12. Conformance checker catches the usual problems.
        check("FRV sidecar is conformant", XMPEdit.validate(frv).isEmpty, "\(XMPEdit.validate(frv))")
        check("Lightroom sidecar is conformant", XMPEdit.validate(lightroom).isEmpty, "\(XMPEdit.validate(lightroom))")
        check("not XMP at all is flagged", !XMPEdit.validate("<html><body/></html>").isEmpty)
        check("undeclared prefix is flagged", !XMPEdit.validate(frv.replacingOccurrences(of: "xmlns:crs=\"http://ns.adobe.com/camera-raw-settings/1.0/\"", with: "")).isEmpty)
        check("bad rating value is flagged", XMPEdit.validate(frv.replacingOccurrences(of: "<xmp:Rating>5</xmp:Rating>", with: "<xmp:Rating>9</xmp:Rating>")).contains { $0.contains("xmp:Rating") })

        print(ok ? "XMP ALL PASSED" : "XMP SOME FAILED")
        return ok
    }
}
