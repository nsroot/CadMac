import AppKit

/// UI language. Source strings are English; Turkish is applied at display time so command
/// logic (which matches English prompts) is unaffected. Command names and option keywords
/// (e.g. `[3P/2P/Diameter]`) stay English, like the shortcut letters they map to.
enum AppLanguage: String, CaseIterable {
    case system, english, turkish

    static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: "AppLanguage") ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "AppLanguage") }
    }

    var title: String {
        switch self {
        case .system: return Loc.isTurkish ? "Sistem dili" : "System Language"
        case .english: return "English"
        case .turkish: return "Türkçe"
        }
    }
}

@MainActor
enum Loc {
    /// Resolved once per launch (changing the language asks for a restart).
    static let isTurkish: Bool = {
        switch AppLanguage.current {
        case .english: return false
        case .turkish: return true
        case .system: return Locale.preferredLanguages.first?.hasPrefix("tr") ?? false
        }
    }()

    /// Translates a UI string: exact match first, then known phrases outside `[...]` and quotes.
    static func t(_ s: String) -> String {
        guard isTurkish, !s.isEmpty else { return s }
        if let e = exact[s] { return e }
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        if let e = exact[trimmed] { return s.replacingOccurrences(of: trimmed, with: e) }
        if let e = exactUpper[s] { return e }
        return phrases(s)
    }

    /// Command summary for autocomplete etc.
    static func summary(_ name: String, _ english: String) -> String {
        guard isTurkish else { return english }
        return commandSummaries[name] ?? t(english)
    }

    // MARK: Phrase translation

    private static let exact: [String: String] = Dictionary(pairs, uniquingKeysWith: { a, _ in a })
    private static let exactUpper: [String: String] = Dictionary(pairs.map { ($0.0.uppercased(), $0.1.uppercased(with: Locale(identifier: "tr"))) }, uniquingKeysWith: { a, _ in a })

    private struct Phrase { let en: String; let tr: String; let regex: NSRegularExpression }

    private static let compiled: [Phrase] = (pairs + messagePhrases)
        .sorted { $0.0.count > $1.0.count }
        .compactMap { en, tr in
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: en) + "(?![\\p{L}])"
            return (try? NSRegularExpression(pattern: pattern)).map { Phrase(en: en, tr: tr, regex: $0) }
        }

    private static func phrases(_ s: String) -> String {
        // Translate only outside [keywords] and "quoted names".
        var out = ""
        var buffer = ""
        var depth = 0
        var inQuote = false
        func flush() { out += translateRun(buffer); buffer = "" }
        for ch in s {
            if ch == "\"" {
                if !inQuote && depth == 0 { flush() }
                inQuote.toggle()
                if inQuote || depth > 0 { out.append(ch) } else { out.append(ch) }
                continue
            }
            if inQuote { out.append(ch); continue }
            if ch == "[" { if depth == 0 { flush() }; depth += 1; out.append(ch); continue }
            if ch == "]" && depth > 0 { depth -= 1; out.append(ch); continue }
            if depth > 0 { out.append(ch) } else { buffer.append(ch) }
        }
        flush()
        return out
    }

    private static func translateRun(_ run: String) -> String {
        guard run.contains(where: { $0.isLetter }) else { return run }
        var s = run
        let lower = run.lowercased()
        for p in compiled where lower.contains(p.en.lowercased()) {
            let range = NSRange(s.startIndex..., in: s)
            s = p.regex.stringByReplacingMatches(in: s, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: p.tr))
        }
        return s
    }

    // MARK: UI walking

    /// Translates static labels, buttons, tooltips and table headers of a view tree.
    static func localize(_ view: NSView) {
        guard isTurkish else { return }
        if let tf = view as? NSTextField {
            if !tf.isEditable && !tf.isBezeled { tf.stringValue = t(tf.stringValue) }
            if let ph = tf.placeholderString { tf.placeholderString = t(ph) }
        } else if let b = view as? NSButton, !(b is TabButton), !(b is NSPopUpButton) {
            // Icon-only buttons keep an invisible default title; leave them alone.
            if !b.title.isEmpty, b.image == nil || b.imagePosition != .imageOnly && b.image == nil { b.title = t(b.title) }
        } else if let seg = view as? NSSegmentedControl {
            for i in 0..<seg.segmentCount { if let l = seg.label(forSegment: i) { seg.setLabel(t(l), forSegment: i) } }
        } else if let table = view as? NSTableView {
            for c in table.tableColumns { c.title = t(c.title) }
        }
        if let tip = view.toolTip { view.toolTip = t(tip) }
        for sub in view.subviews { localize(sub) }
    }

    static func localize(_ menu: NSMenu) {
        guard isTurkish else { return }
        menu.title = t(menu.title)
        for item in menu.items {
            // Command menu items are "Title    ALIAS".
            if let r = item.title.range(of: "    ") {
                item.title = t(String(item.title[..<r.lowerBound])) + item.title[r.lowerBound...]
            } else {
                item.title = t(item.title)
            }
            if let tip = item.toolTip { item.toolTip = t(tip) }
            if let sub = item.submenu { localize(sub) }
        }
    }

    /// Localizes alerts, sheets and new windows as they appear.
    static func installWindowObserver() {
        guard isTurkish else { return }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { n in
            MainActor.assumeIsolated {
                guard let w = n.object as? NSWindow, let v = w.contentView else { return }
                localize(v)
            }
        }
    }

    // MARK: Tables

    /// UI strings and command prompts (exact strings and phrases).
    static let pairs: [(String, String)] = [
        // Menus
        ("About CadMac", "CadMac Hakkında"), ("Services", "Hizmetler"), ("Hide CadMac", "CadMac'i Gizle"), ("Hide Others", "Diğerlerini Gizle"),
        ("Show All", "Tümünü Göster"), ("Quit CadMac", "CadMac'ten Çık"), ("Language", "Dil"),
        ("File", "Dosya"), ("New", "Yeni"), ("Open…", "Aç…"), ("Open Recent", "Son Kullanılanlar"), ("Clear Menu", "Menüyü Temizle"),
        ("Close", "Kapat"), ("Save", "Kaydet"), ("Save As…", "Farklı Kaydet…"), ("Revert to Saved", "Kaydedilene Döndür"),
        ("Export as PDF…", "PDF Olarak Dışa Aktar…"), ("Publish All Layouts to PDF…", "Tüm Layout'ları PDF'e Yayınla…"),
        ("Print / Plot…", "Yazdır / Çiz…"),
        ("Edit", "Düzen"), ("Undo", "Geri Al"), ("Redo", "Yinele"), ("Cut", "Kes"), ("Copy", "Kopyala"), ("Paste", "Yapıştır"),
        ("Delete", "Sil"), ("Select All", "Tümünü Seç"),
        ("View", "Görünüm"), ("Zoom Extents", "Tümünü Göster (Zoom Extents)"), ("Zoom In", "Yakınlaştır"), ("Zoom Out", "Uzaklaştır"),
        ("Zoom Window", "Pencereyle Yakınlaştır"), ("Regenerate", "Yenile (Regen)"),
        ("Object Snap (F3)", "Nesne Yakalama (F3)"), ("Grid (F7)", "Izgara (F7)"), ("Ortho (F8)", "Ortho (F8)"), ("Snap (F9)", "Snap (F9)"),
        ("Polar Tracking (F10)", "Polar İzleme (F10)"), ("Object Snap Tracking (F11)", "Nesne Yakalama İzleme (F11)"),
        ("Dynamic Input (F12)", "Dinamik Giriş (F12)"),
        ("Hide Tool Sets", "Araç Paletini Gizle"), ("Show Tool Sets", "Araç Paletini Göster"),
        ("Hide Inspector", "Sağ Paneli Gizle"), ("Show Inspector", "Sağ Paneli Göster"),
        ("Hide Command Line", "Komut Satırını Gizle"), ("Show Command Line", "Komut Satırını Göster"), ("Toggle Command Line", "Komut Satırı"),
        ("Dark Background", "Koyu Arka Plan"), ("Enter Full Screen", "Tam Ekrana Geç"),
        ("Draw", "Çizim"), ("Modify", "Değiştir"), ("Dimension", "Ölçü"), ("Format", "Biçim"), ("Tools", "Araçlar"),
        ("Window", "Pencere"), ("Help", "Yardım"), ("Minimize", "Küçült"), ("Zoom", "Yakınlaştır"), ("Bring All to Front", "Tümünü Öne Getir"),
        ("Command List", "Komut Listesi"),
        // Draw menu
        ("Line", "Çizgi"), ("Polyline", "Polyline"), ("Rectangle", "Dikdörtgen"), ("Polygon", "Çokgen"), ("Circle", "Daire"), ("Arc", "Yay"),
        ("Ellipse", "Elips"), ("Spline", "Spline"), ("Donut", "Halka"), ("Construction Line", "Yardımcı Çizgi"), ("Ray", "Işın"),
        ("Point", "Nokta"), ("Divide", "Eşit Böl"), ("Measure", "Aralıkla Böl"), ("Hatch…", "Tarama…"), ("Revision Cloud", "Revizyon Bulutu"),
        ("Single Line Text", "Tek Satır Yazı"), ("Multiline Text", "Çok Satırlı Yazı"), ("Make Block", "Blok Oluştur"),
        ("Insert Block", "Blok Ekle"), ("Block Editor", "Blok Düzenleyici"), ("Save Block", "Bloğu Kaydet"), ("Close Block Editor", "Blok Düzenleyiciyi Kapat"),
        // Modify menu
        ("Erase", "Sil"), ("Move", "Taşı"), ("Rotate", "Döndür"), ("Scale", "Ölçekle"), ("Mirror", "Aynala"), ("Stretch", "Esnet"),
        ("Offset", "Ötele (Offset)"), ("Trim", "Kırp"), ("Extend", "Uzat"), ("Lengthen", "Uzunluk Değiştir"), ("Break", "Kes (Break)"),
        ("Join", "Birleştir"), ("Fillet", "Yuvarla (Fillet)"), ("Chamfer", "Pah Kır"), ("Rectangular Array", "Dikdörtgen Dizi"),
        ("Polar Array", "Polar Dizi"), ("Path Array", "Yol Boyunca Dizi"), ("Explode", "Patlat"), ("Match Properties", "Özellik Eşle"),
        ("Properties", "Özellikler"),
        // Dimension / Format / Tools menus
        ("Linear", "Doğrusal"), ("Aligned", "Hizalı"), ("Angular", "Açısal"), ("Radius", "Yarıçap"), ("Diameter", "Çap"),
        ("Continue", "Devam (Zincir)"), ("Baseline", "Taban Çizgisi"), ("Leader", "Leader"),
        ("Dimension Scale…", "Ölçü Ölçeği…"), ("Dimension Text Height…", "Ölçü Yazı Yüksekliği…"), ("Arrow Size…", "Ok Boyutu…"),
        ("Decimal Places…", "Ondalık Hane…"),
        ("Layers…", "Katmanlar…"), ("Make Object's Layer Current", "Nesnenin Katmanını Geçerli Yap"), ("Layer Off", "Katmanı Kapat"),
        ("Layer Isolate", "Katmanı Yalıt"), ("All Layers On", "Tüm Katmanları Aç"), ("Thaw All Layers", "Tüm Katmanları Çöz"),
        ("Lock Layer", "Katmanı Kilitle"), ("Unlock Layer", "Katman Kilidini Aç"), ("Text Height…", "Yazı Yüksekliği…"),
        ("Linetype Scale…", "Çizgi Tipi Ölçeği…"), ("Grid Spacing…", "Izgara Aralığı…"), ("Snap Spacing…", "Snap Aralığı…"),
        ("Purge Unused…", "Kullanılmayanları Temizle…"),
        ("Distance", "Mesafe"), ("Area", "Alan"), ("Point Coordinates", "Nokta Koordinatı"), ("List", "Listele"),
        ("Object Snap Settings…", "Nesne Yakalama Ayarları…"), ("Set Variable…", "Değişken Ayarla…"),
        // Panels, toolbar, status
        ("Layers", "Katmanlar"), ("LAYERS", "KATMANLAR"), ("Set Current", "Geçerli Yap"), ("Name", "Ad"), ("On", "Açık"), ("Freeze", "Dondur"),
        ("Lock", "Kilit"), ("Color", "Renk"), ("Linetype", "Çizgi Tipi"), ("Lineweight", "Çizgi Kalınlığı"),
        ("General", "Genel"), ("Geometry", "Geometri"), ("Layer", "Katman"), ("Units", "Birimler"), ("No selection", "Seçim yok"),
        ("Text height", "Yazı yüksekliği"), ("Dim scale", "Ölçü ölçeği"), ("LT scale", "Çizgi tipi ölçeği"), ("Grid spacing", "Izgara aralığı"),
        ("Select Color…", "Renk Seç…"), ("Tool Sets", "Araç Paleti"), ("Inspector", "Sağ Panel"), ("Command Line", "Komut Satırı"),
        ("Annotation", "Açıklama"), ("Block & Tools", "Blok ve Araçlar"),
        ("Start X", "Başlangıç X"), ("Start Y", "Başlangıç Y"), ("End X", "Bitiş X"), ("End Y", "Bitiş Y"), ("Length", "Uzunluk"),
        ("Angle", "Açı"), ("Center X", "Merkez X"), ("Center Y", "Merkez Y"), ("Circumference", "Çevre"), ("Start angle", "Başlangıç açısı"),
        ("End angle", "Bitiş açısı"), ("Arc length", "Yay uzunluğu"), ("Vertices", "Köşe sayısı"), ("Closed", "Kapalı"),
        ("Global width", "Genel kalınlık"), ("Contents", "İçerik"), ("Height", "Yükseklik"), ("Rotation", "Döndürme"),
        ("Position X", "Konum X"), ("Position Y", "Konum Y"), ("Major radius", "Büyük yarıçap"), ("Radius ratio", "Yarıçap oranı"),
        ("Measurement", "Ölçülen değer"), ("Text override", "Yazı (override)"), ("Block", "Blok"), ("Scale X", "Ölçek X"), ("Scale Y", "Ölçek Y"),
        ("Pattern", "Desen"), ("Spacing", "Aralık"), ("Points", "Nokta sayısı"), ("Width", "Genişlik"), ("View center X", "Görünüm merkezi X"),
        ("View center Y", "Görünüm merkezi Y"), ("Locked", "Kilitli"), ("Frozen layers", "Dondurulmuş katmanlar"), ("Tag", "Etiket"),
        ("Prompt", "İstem"), ("Default", "Varsayılan"),
        ("Choose DXF or DWG under File Format. DWG is written by CadMac in AutoCAD 2000 format: true colors become the nearest indexed color and objects CadMac cannot hold are left out. Keep a copy of important originals.",
         "Dosya Biçimi'nden DXF veya DWG seçin. DWG, CadMac'ın kendi yazıcısıyla AutoCAD 2000 biçiminde yazılır: gerçek renkler en yakın dizin rengine dönüşür ve CadMac'in taşıyamadığı nesneler dosyaya girmez. Önemli orijinallerin bir kopyasını saklayın."),
        ("%1$@ DWG · %2$@ objects · %3$@ entities", "%1$@ DWG · %2$@ nesne · %3$@ çizim nesnesi"),
        ("Some objects were not imported", "Bazı nesneler içe aktarılmadı"),
        ("Objects left out", "Dışarıda kalan nesneler"), ("more types", "diğer tip"),
        ("Parts of the file CadMac read imperfectly", "CadMac'in tam okuyamadığı dosya bölümleri"),
        ("Broken references", "Kırık referanslar"),
        ("CadMac has no model for them, so saving will not write them back. Keep the original file.",
         "CadMac bunları temsil edemiyor; kaydedince dosyaya geri yazılmazlar. Orijinal dosyanın bir kopyasını saklayın."),
        ("File Format", "Dosya Biçimi"), ("DXF Drawing", "DXF Çizimi"), ("DWG Drawing", "DWG Çizimi"),
        ("Millimeters", "Milimetre"), ("Centimeters", "Santimetre"), ("Meters", "Metre"), ("Inches", "İnç"), ("Feet", "Feet"),
        ("Unitless", "Birimsiz"), ("Model", "Model"), ("paper, mm", "kağıt, mm"),
        ("Command:", "Komut:"), ("Type a command", "Bir komut yazın"), ("Tab to complete", "Tab ile tamamla"),
        ("Model", "Model"), ("New layout", "Yeni layout"), ("All layouts", "Tüm layout'lar"),
        ("Rename…", "Yeniden Adlandır…"), ("Page Setup…", "Sayfa Ayarı…"), ("Move Left", "Sola Taşı"), ("Move Right", "Sağa Taşı"),
        ("Delete Layout", "Layout'u Sil"), ("New Layout", "Yeni Layout"), ("Rename Layout", "Layout'u Yeniden Adlandır"),
        ("Portrait", "Dikey"), ("Landscape", "Yatay"), ("Cancel", "Vazgeç"), ("OK", "Tamam"), ("Rename", "Yeniden Adlandır"),
        ("Don't Save", "Kaydetme"), ("Recover", "Kurtar"), ("Delete Backups", "Yedekleri Sil"), ("Later", "Sonra"),
        ("Object Snap Modes", "Nesne Yakalama Modları"), ("Select the snap points to use while picking points.", "Nokta seçerken kullanılacak yakalama noktalarını seçin."),
        ("Multiline Text", "Çok Satırlı Yazı"), ("Edit Text", "Yazıyı Düzenle"), ("Edit Multiline Text", "Çok Satırlı Yazıyı Düzenle"),
        ("Recover unsaved drawings?", "Kaydedilmemiş çizimler kurtarılsın mı?"),
        ("CadMac did not close normally. Automatic backups were found:", "CadMac düzgün kapanmadı. Otomatik yedekler bulundu:"),
        ("Publishing…", "Yayınlanıyor…"), ("Publishing", "Yayınlanıyor"),
        ("BLOCK EDITOR", "BLOK DÜZENLEYİCİ"),
        ("Edits apply to every reference of this block when saved. The yellow marker is the base point.", "Kaydedince değişiklikler bu bloğun tüm kopyalarına uygulanır. Sarı işaret taban noktasıdır."),
        ("If you don't save, your changes to the block definition will be lost.", "Kaydetmezseniz blok tanımındaki değişiklikler kaybolur."),
        ("Paper size for this layout. Existing objects keep their position.", "Bu layout'un kağıt boyutu. Mevcut nesneler yerinde kalır."),
        ("Real-world size of one drawing unit. Changing it does not scale geometry.", "Bir çizim biriminin gerçek boyutu. Değiştirmek geometriyi ölçeklemez."),
        // Snap labels / overlay
        ("Endpoint", "Uç nokta"), ("Midpoint", "Orta nokta"), ("Center", "Merkez"), ("Quadrant", "Çeyrek"), ("Intersection", "Kesişim"),
        ("Perpendicular", "Dik"), ("Tangent", "Teğet"), ("Nearest", "En yakın"), ("Node", "Düğüm"), ("Insertion", "Ekleme noktası"),
        ("Track", "İz"), ("Intersection of tracks", "İzlerin kesişimi"), ("Base point", "Taban noktası"),
        // Command prompts
        ("Specify first point", "İlk noktayı belirtin"), ("Specify next point", "Sonraki noktayı belirtin"),
        ("Specify next point (Enter for text)", "Sonraki noktayı belirtin (yazı için Enter)"),
        ("Specify next point (Enter to compute)", "Sonraki noktayı belirtin (hesaplamak için Enter)"),
        ("Specify start point", "Başlangıç noktasını belirtin"), ("Specify a point", "Bir nokta belirtin"), ("Specify point", "Nokta belirtin"),
        ("Specify through point", "Geçeceği noktayı belirtin"), ("Specify endpoint of arc", "Yayın bitiş noktasını belirtin"),
        ("Specify width", "Kalınlığı belirtin"), ("Specify first corner point", "İlk köşe noktasını belirtin"),
        ("Specify other corner point", "Diğer köşe noktasını belirtin"), ("Specify center point for circle", "Dairenin merkez noktasını belirtin"),
        ("Specify radius of circle", "Dairenin yarıçapını belirtin"), ("Specify diameter of circle", "Dairenin çapını belirtin"),
        ("Specify first point on circle", "Daire üzerindeki ilk noktayı belirtin"), ("Specify second point on circle", "Daire üzerindeki ikinci noktayı belirtin"),
        ("Specify third point on circle", "Daire üzerindeki üçüncü noktayı belirtin"),
        ("Specify first end point of circle's diameter", "Çapın ilk uç noktasını belirtin"),
        ("Specify second end point of circle's diameter", "Çapın ikinci uç noktasını belirtin"),
        ("Specify start point of arc", "Yayın başlangıç noktasını belirtin"), ("Specify center point of arc", "Yayın merkez noktasını belirtin"),
        ("Specify second point of arc", "Yayın ikinci noktasını belirtin"), ("Specify end point of arc", "Yayın bitiş noktasını belirtin"),
        ("Specify end point of arc (hold direction CCW)", "Yayın bitiş noktasını belirtin (saat yönünün tersine)"),
        ("Specify axis endpoint of ellipse", "Elipsin eksen uç noktasını belirtin"), ("Specify center of ellipse", "Elipsin merkezini belirtin"),
        ("Specify other endpoint of axis", "Eksenin diğer uç noktasını belirtin"), ("Specify endpoint of axis", "Eksenin uç noktasını belirtin"),
        ("Specify distance to other axis", "Diğer eksene uzaklığı belirtin"), ("Enter number of sides", "Kenar sayısını girin"),
        ("Specify center of polygon", "Çokgenin merkezini belirtin"), ("Specify first endpoint of edge", "Kenarın ilk uç noktasını belirtin"),
        ("Specify second endpoint of edge", "Kenarın ikinci uç noktasını belirtin"),
        ("Specify inside diameter of donut", "Halkanın iç çapını belirtin"), ("Specify outside diameter of donut", "Halkanın dış çapını belirtin"),
        ("Specify center of donut", "Halkanın merkezini belirtin"), ("Enter next point", "Sonraki noktayı girin"),
        ("Specify first corner point (rectangular cloud)", "İlk köşe noktasını belirtin (dikdörtgen bulut)"),
        ("Specify arc length", "Yay uzunluğunu belirtin"), ("Specify opposite corner", "Karşı köşeyi belirtin"),
        ("Pick internal point", "İç noktaya tıklayın"), ("Select closed objects", "Kapalı nesneleri seçin"),
        ("Enter pattern name", "Desen adını girin"), ("Specify spacing", "Aralığı belirtin"), ("Specify angle", "Açıyı belirtin"),
        ("Specify start point of text", "Yazının başlangıç noktasını belirtin"), ("Specify height", "Yüksekliği belirtin"),
        ("Specify rotation angle of text", "Yazının döndürme açısını belirtin"), ("Enter text", "Yazıyı girin"),
        ("Enter justification", "Hizalamayı girin"), ("Specify first corner", "İlk köşeyi belirtin"), ("Enter text in the editor", "Yazıyı düzenleyicide girin"),
        ("Select objects", "Nesneleri seçin"), ("Specify base point", "Taban noktasını belirtin"), ("Specify second point", "İkinci noktayı belirtin"),
        ("Specify displacement (dx,dy)", "Yer değiştirmeyi belirtin (dx,dy)"), ("Specify rotation angle", "Döndürme açısını belirtin"),
        ("Specify the reference angle", "Referans açıyı belirtin"), ("Specify the new angle", "Yeni açıyı belirtin"),
        ("Specify scale factor", "Ölçek çarpanını belirtin"), ("Specify reference length", "Referans uzunluğu belirtin"),
        ("Specify new length", "Yeni uzunluğu belirtin"), ("Specify first point of mirror line", "Ayna çizgisinin ilk noktasını belirtin"),
        ("Specify second point of mirror line", "Ayna çizgisinin ikinci noktasını belirtin"), ("Erase source objects?", "Kaynak nesneler silinsin mi?"),
        ("Specify offset distance", "Öteleme mesafesini belirtin"), ("Select object to offset", "Ötelenecek nesneyi seçin"),
        ("Specify point on side to offset", "Öteleme tarafındaki bir noktayı belirtin"),
        ("Select object to trim", "Kırpılacak nesneyi seçin"), ("Select object to extend", "Uzatılacak nesneyi seçin"), ("Select edges", "Kenarları seçin"),
        ("Select first object", "İlk nesneyi seçin"), ("Select second object", "İkinci nesneyi seçin"), ("Select first line", "İlk çizgiyi seçin"),
        ("Select second line", "İkinci çizgiyi seçin"), ("Specify fillet radius", "Yuvarlama yarıçapını belirtin"),
        ("Specify first chamfer distance", "İlk pah mesafesini belirtin"), ("Specify second chamfer distance", "İkinci pah mesafesini belirtin"),
        ("Select 2D polyline", "2B polyline seçin"), ("Select object", "Nesne seçin"),
        ("Specify second break point (Enter = break at point)", "İkinci kesme noktasını belirtin (Enter = noktadan böl)"),
        ("Specify first break point", "İlk kesme noktasını belirtin"), ("Specify second break point", "İkinci kesme noktasını belirtin"),
        ("Select an object to change", "Değiştirilecek nesneyi seçin"), ("Enter delta length", "Fark uzunluğunu girin"),
        ("Enter percentage length", "Yüzde uzunluğu girin"), ("Specify total length", "Toplam uzunluğu belirtin"),
        ("Enter array type", "Dizi türünü girin"), ("Enter number of rows", "Satır sayısını girin"), ("Enter number of columns", "Sütun sayısını girin"),
        ("Specify the distance between rows", "Satırlar arası mesafeyi belirtin"), ("Specify the distance between columns", "Sütunlar arası mesafeyi belirtin"),
        ("Specify center point of array", "Dizinin merkez noktasını belirtin"), ("Enter number of items", "Öğe sayısını girin"),
        ("Enter number of items along path", "Yol boyunca öğe sayısını girin"), ("Specify the angle to fill", "Doldurulacak açıyı belirtin"),
        ("Select path curve", "Yol eğrisini seçin"), ("Select source object", "Kaynak nesneyi seçin"), ("Select destination object(s)", "Hedef nesne(ler)i seçin"),
        ("Select object to measure", "Ölçülecek nesneyi seçin"), ("Select object to divide", "Bölünecek nesneyi seçin"),
        ("Specify length of segment", "Parça uzunluğunu belirtin"), ("Enter the number of segments", "Parça sayısını girin"),
        ("Specify first extension line origin", "İlk uzatma çizgisinin başlangıcını belirtin"),
        ("Specify second extension line origin", "İkinci uzatma çizgisinin başlangıcını belirtin"),
        ("Specify a second extension line origin", "İkinci uzatma çizgisinin başlangıcını belirtin"),
        ("Select object to dimension", "Ölçülendirilecek nesneyi seçin"), ("Specify dimension line location", "Ölçü çizgisinin yerini belirtin"),
        ("Specify angle of dimension line", "Ölçü çizgisinin açısını belirtin"), ("Select arc or circle", "Yay veya daire seçin"),
        ("Select arc, circle, line", "Yay, daire veya çizgi seçin"), ("Specify dimension arc line location", "Ölçü yayının yerini belirtin"),
        ("Specify leader arrowhead location", "Ok ucunun yerini belirtin"), ("Enter annotation text", "Açıklama yazısını girin"),
        ("Enter block name", "Blok adını girin"), ("Specify insertion base point", "Ekleme taban noktasını belirtin"),
        ("Specify insertion point", "Ekleme noktasını belirtin"), ("Specify second point", "İkinci noktayı belirtin"),
        ("Specify first corner of window, enter a scale factor (nX), or", "Pencere köşesini belirtin, ölçek girin (nX) veya"),
        ("Specify corner of window, enter a scale factor (nX), or", "Pencere köşesini belirtin, ölçek girin (nX) veya"),
        ("Select an object on the target layer", "Hedef katmandaki bir nesneyi seçin"), ("Enter variable name", "Değişken adını girin"),
        ("Enter new value for", "Yeni değeri girin:"), ("Specify drawing units", "Çizim birimini belirtin"),
        ("Enter automatic save interval in minutes (0 = off)", "Otomatik kaydetme aralığını dakika olarak girin (0 = kapalı)"),
        ("Enter layout option", "Layout seçeneğini girin"), ("Enter new layout name", "Yeni layout adını girin"),
        ("Enter layout to rename", "Yeniden adlandırılacak layout'u girin"), ("Enter layout to delete", "Silinecek layout'u girin"),
        ("Enter layout to make current (or Model)", "Geçerli yapılacak layout'u girin (veya Model)"),
        ("Specify corner of viewport", "Viewport köşesini belirtin"), ("Select a block reference or enter block name", "Bir blok seçin veya blok adını girin"),
        ("Enter attribute tag name", "Attribute etiket adını girin"), ("Enter attribute prompt", "Attribute istemini girin"),
        ("Enter default attribute value", "Varsayılan attribute değerini girin"), ("Select block reference", "Blok seçin"),
        ("Specify first source point", "İlk kaynak noktasını belirtin"), ("Specify first destination point", "İlk hedef noktasını belirtin"),
        ("Specify second source point or <continue>", "İkinci kaynak noktasını belirtin veya <devam>"),
        ("Specify second destination point", "İkinci hedef noktasını belirtin"),
        ("Specify third source point or <continue>", "Üçüncü kaynak noktasını belirtin veya <devam>"),
        ("Scale objects based on alignment points?", "Nesneler hizalama noktalarına göre ölçeklensin mi?"),
        ("Enter object ordering option", "Sıralama seçeneğini girin"), ("Select reference objects", "Referans nesneleri seçin"),
        ("Bring to front", "Öne getir"), ("Enter a group name or", "Grup adını girin veya"), ("Enter group description", "Grup açıklamasını girin"),
        ("Select group", "Grup seçin"), ("Enter an option", "Bir seçenek girin"), ("Select objects to add to the group", "Gruba eklenecek nesneleri seçin"),
        ("Select objects to remove from the group", "Gruptan çıkarılacak nesneleri seçin"), ("Enter new name for group", "Grubun yeni adını girin"),
        ("Select a block reference to count", "Sayılacak bloğu seçin"), ("Enter text to find", "Aranacak yazıyı girin"),
        ("Enter replacement text or <select matches>", "Yeni yazıyı girin veya <eşleşenleri seç>"),
        ("Specify text height", "Yazı yüksekliğini belirtin"), ("Specify rotation angle", "Döndürme açısını belirtin"),
    ]

    /// Fragments of longer messages (results, warnings).
    static let messagePhrases: [(String, String)] = [
        ("Distance", "Mesafe"), ("Angle in XY Plane", "XY düzlemindeki açı"), ("Perimeter", "Çevre"), ("Area", "Alan"),
        ("Object is open. Length", "Nesne açık. Uzunluk"), ("Area cannot be computed for this object", "Bu nesnenin alanı hesaplanamaz"),
        ("object(s) erased", "nesne silindi"), ("object(s) copied", "nesne kopyalandı"), ("object(s) exploded", "nesne patlatıldı"),
        ("object(s) selected", "nesne seçildi"), ("objects joined into", "nesne birleştirildi →"), ("item(s) created", "öğe oluşturuldu"),
        ("point(s) placed", "nokta yerleştirildi"), ("unused item(s) purged", "kullanılmayan öğe temizlendi"),
        ("found, ", "bulundu, "), ("total", "toplam"), ("selected", "seçildi"), ("found", "bulundu"),
        ("Unknown command", "Bilinmeyen komut"), ("Press F1 for the user guide.", "Kılavuz için F1'e basın."),
        ("Invalid input.", "Geçersiz giriş."), ("Nothing to undo", "Geri alınacak bir şey yok"), ("Nothing to redo", "Yinelenecek bir şey yok"),
        ("No object found", "Nesne bulunamadı"), ("Object is on a locked layer", "Nesne kilitli bir katmanda"), ("Nothing selected", "Seçim yok"),
        ("Clipboard is empty", "Pano boş"), ("Snap override", "Tek seferlik yakalama"), ("Dimension text", "Ölçü yazısı"),
        ("Valid hatch boundary not found.", "Geçerli tarama sınırı bulunamadı."), ("No closed objects selected", "Kapalı nesne seçilmedi"),
        ("Rectangle has zero size", "Dikdörtgenin boyutu sıfır"), ("Selected objects cannot be exploded", "Seçili nesneler patlatılamaz"),
        ("Object cannot be dimensioned", "Bu nesne ölçülendirilemez"), ("Select an arc or circle", "Bir yay veya daire seçin"),
        ("Select an arc or line", "Bir yay veya çizgi seçin"), ("Select a line", "Bir çizgi seçin"), ("Lines are parallel", "Çizgiler paralel"),
        ("Object must be closed", "Nesne kapalı olmalı"), ("Polyline chamfer is not supported yet", "Polyline pah kırma henüz desteklenmiyor"),
        ("Object cannot be trimmed", "Nesne kırpılamaz"), ("Object cannot be extended", "Nesne uzatılamaz"),
        ("No intersection found", "Kesişim bulunamadı"), ("Radius is too large", "Yarıçap çok büyük"), ("Distance is too large", "Mesafe çok büyük"),
        ("Cannot offset that object", "Bu nesne ötelenemez"), ("Offset distance is too large", "Öteleme mesafesi çok büyük"),
        ("Cannot fillet these objects", "Bu nesneler yuvarlanamaz"), ("Cannot chamfer these objects", "Bu nesnelere pah kırılamaz"),
        ("Object cannot be broken", "Nesne kesilemez"), ("Arc cannot be full 360 degrees", "Yay tam 360 derece olamaz"),
        ("Objects cannot be joined", "Nesneler birleştirilemez"), ("Object cannot be lengthened", "Nesne uzatılamaz"),
        ("Invalid length", "Geçersiz uzunluk"), ("Value must be positive", "Değer pozitif olmalı"),
        ("Drawing units set to", "Çizim birimi ayarlandı:"), ("Current drawing units", "Geçerli çizim birimi"),
        ("Changing units does not scale existing geometry.", "Birimi değiştirmek mevcut geometriyi ölçeklemez."),
        ("Switched to layout", "Layout'a geçildi:"), ("Double-click inside a viewport to pan/zoom its view.", "Görünümü kaydırmak/yakınlaştırmak için viewport'un içine çift tıklayın."),
        ("Switched to Model space.", "Model alanına geçildi."), ("Layouts", "Layout'lar"), ("Layout", "Layout"),
        ("A drawing must keep at least one layout.", "Çizimde en az bir layout kalmalı."), ("Invalid or duplicate layout name.", "Geçersiz veya tekrarlanan layout adı."),
        ("Page setup applies to layouts. Switch to a layout tab first.", "Sayfa ayarı layout'lar içindir. Önce bir layout sekmesine geçin."),
        ("MVIEW works in a layout. Switch to a layout tab first.", "MVIEW layout'ta çalışır. Önce bir layout sekmesine geçin."),
        ("Viewport created at scale", "Viewport oluşturuldu, ölçek"), ("Double-click inside it to pan/zoom; set an exact scale in Properties.", "Kaydırmak/yakınlaştırmak için içine çift tıklayın; tam ölçeği Özellikler'den girin."),
        ("Viewport active (scale", "Viewport etkin (ölçek"), ("scroll to pan, pinch / wheel to zoom. Esc or double-click outside to finish.", "kaydırarak pan, sıkıştırma/tekerlek ile zoom. Bitirmek için Esc veya dışarıya çift tıklayın."),
        ("Viewport is locked. Unlock it in Properties (Locked = No) to pan or zoom its view.", "Viewport kilitli. Görünümünü değiştirmek için Özellikler'de Locked = No yapın."),
        ("Viewport scale", "Viewport ölçeği"), ("Opened block", "Blok açıldı:"), ("in the Block Editor.", "(Blok Düzenleyici)."),
        ("has no definition in this drawing (it may not have been converted from the DWG).", "bu çizimde tanımlı değil (DWG'den dönüştürülmemiş olabilir)."),
        ("updated", "güncellendi"), ("reference(s) in the drawing", "kopya"), ("saved.", "kaydedildi."),
        ("BSAVE is only available in the Block Editor.", "BSAVE yalnızca Blok Düzenleyici'de kullanılabilir."),
        ("BCLOSE is only available in the Block Editor.", "BCLOSE yalnızca Blok Düzenleyici'de kullanılabilir."),
        ("No blocks defined in this drawing.", "Bu çizimde blok tanımı yok."), ("Use BLOCK first.", "Önce BLOCK kullanın."), ("Blocks", "Bloklar"),
        ("created with", "oluşturuldu,"), ("object(s)", "nesne"), ("already exists and will be redefined.", "zaten var, yeniden tanımlanacak."),
        ("not found", "bulunamadı"), ("Published", "Yayınlandı:"), ("layout(s) to", "layout →"), ("Could not write", "Yazılamadı:"),
        ("This drawing has no layouts to publish.", "Bu çizimde yayınlanacak layout yok."),
        ("Command line hidden — type anywhere; input appears at the cursor.", "Komut satırı gizlendi — her yere yazabilirsiniz; giriş imlecin yanında görünür."),
        ("shows it again.", "tekrar gösterir."), ("Automatic save is off.", "Otomatik kaydetme kapalı."),
        ("Drawings are backed up every", "Çizimler şu aralıkla yedekleniyor:"), ("minutes.", "dakika."),
        ("object(s) isolated. Use UNISOLATEOBJECTS to show everything again.", "nesne yalıtıldı. Hepsini tekrar göstermek için UNISOLATEOBJECTS."),
        ("object(s) hidden. Use UNISOLATEOBJECTS to show them again.", "nesne gizlendi. Tekrar göstermek için UNISOLATEOBJECTS."),
        ("No objects are hidden.", "Gizli nesne yok."), ("object(s) shown again.", "nesne tekrar gösterildi."),
        ("Current settings", "Geçerli ayarlar"), ("Current active settings", "Geçerli etkin ayarlar"), ("Layer", "Katman"), ("Color", "Renk"),
        ("Linetype", "Çizgi tipi"), ("from point", "başlangıç"), ("to point", "bitiş"), ("center point", "merkez"), ("radius", "yarıçap"),
        ("circumference", "çevre"), ("area", "alan"), ("length", "uzunluk"), ("start angle", "başlangıç açısı"), ("end angle", "bitiş açısı"),
        ("vertices", "köşe"), ("Open", "Açık"), ("Undo", "Geri al"), ("Redo", "Yinele"), ("Command", "Komut"),
        ("Pan with two-finger scroll or middle mouse drag. Zoom with pinch or mouse wheel.", "Pan: iki parmakla kaydırma veya orta tuşla sürükleme. Zoom: sıkıştırma veya tekerlek."),
        ("Use a crossing window (drag right-to-left) to select objects to stretch.", "Esnetilecek nesneleri crossing pencereyle (sağdan sola) seçin."),
        ("Select objects to stretch by crossing-window...", "Esnetilecek nesneleri crossing pencereyle seçin..."),
        ("No linear dimension to continue. Create one with DIMLINEAR first.", "Devam edilecek doğrusal ölçü yok. Önce DIMLINEAR ile oluşturun."),
        ("Group", "Grup"), ("No groups defined.", "Tanımlı grup yok."), ("Invalid group name.", "Geçersiz grup adı."),
        ("No matches found for", "Eşleşme bulunamadı:"), ("replacement(s) made.", "değişiklik yapıldı."), ("Total", "Toplam"),
        ("block reference(s)", "blok kopyası"), ("block(s)", "blok"), ("duplicate(s) deleted", "kopya silindi"),
        ("overlapping object(s) or segment(s) deleted", "çakışan nesne/parça silindi"), ("object(s) reordered", "nesnenin sırası değişti"),
        ("object(s) brought to front", "nesne öne getirildi"), ("attribute(s) updated", "attribute güncellendi"),
        ("QSELECT needs a drawing window.", "QSELECT için bir çizim penceresi gerekli."),
        ("Third point pair is ignored for 2D alignment.", "Üçüncü nokta çifti 2B hizalamada yok sayılır."),
        ("Claude wants to", "Claude şunu yapmak istiyor"), ("applied", "uygulandı"), ("rejected", "reddedildi"),
        ("Apply", "Uygula"), ("Reject", "Reddet"), ("in the panel", "panelden"),
    ]

    /// Turkish summaries for the command list / autocomplete.
    static let commandSummaries: [String: String] = [
        "LINE": "Düz çizgi parçaları", "PLINE": "2B polyline", "RECTANG": "Dikdörtgen", "CIRCLE": "Daire", "ARC": "Yay", "ELLIPSE": "Elips",
        "POLYGON": "Düzgün çokgen", "POINT": "Nokta", "SPLINE": "Eğri", "DONUT": "Dolu halka", "XLINE": "Yardımcı çizgi", "RAY": "Işın",
        "REVCLOUD": "Revizyon bulutu", "HATCH": "Tarama", "TEXT": "Tek satır yazı", "MTEXT": "Çok satırlı yazı", "ERASE": "Sil", "MOVE": "Taşı",
        "COPY": "Kopyala", "ROTATE": "Döndür", "SCALE": "Ölçekle", "MIRROR": "Aynala", "STRETCH": "Esnet", "OFFSET": "Paralel kopya",
        "TRIM": "Kırp", "EXTEND": "Uzat", "FILLET": "Köşe yuvarla", "CHAMFER": "Pah kır", "BREAK": "Kes", "JOIN": "Birleştir",
        "EXPLODE": "Patlat", "LENGTHEN": "Uzunluk değiştir", "ARRAY": "Dizi", "MATCHPROP": "Özellik eşle", "DIVIDE": "Eşit böl",
        "MEASURE": "Aralıkla böl", "DIMLINEAR": "Doğrusal ölçü", "DIMALIGNED": "Hizalı ölçü", "DIMRADIUS": "Yarıçap ölçüsü",
        "DIMDIAMETER": "Çap ölçüsü", "DIMANGULAR": "Açı ölçüsü", "DIMCONTINUE": "Zincir ölçü", "DIMBASELINE": "Taban ölçü",
        "QLEADER": "Ok ve yazı", "BLOCK": "Blok oluştur", "INSERT": "Blok ekle", "BEDIT": "Blok düzenleyici", "DIST": "Mesafe ölç",
        "AREA": "Alan ve çevre", "ID": "Nokta koordinatı", "LIST": "Nesne bilgisi", "UNITS": "Çizim birimi", "ZOOM": "Yakınlaştır",
        "LAYER": "Katmanlar", "PROPERTIES": "Özellikler", "UNDO": "Geri al", "REDO": "Yinele", "PURGE": "Temizle", "PLOT": "Yazdır",
        "EXPORTPDF": "PDF'e aktar", "PUBLISH": "Tüm layout'ları PDF'e", "LAYOUT": "Layout işlemleri", "MVIEW": "Viewport oluştur",
        "MODEL": "Model sekmesi", "PAGESETUP": "Sayfa ayarı", "HELP": "Kullanım kılavuzu", "QSELECT": "Hızlı seçim", "ALIGN": "Hizala",
        "DRAWORDER": "Çizim sırası", "GROUP": "Grup oluştur", "UNGROUP": "Grubu çöz", "OVERKILL": "Çift nesneleri temizle",
        "COUNT": "Blokları say", "FIND": "Yazı bul/değiştir", "ATTDEF": "Attribute tanımı", "ATTEDIT": "Attribute düzenle",
        "ISOLATEOBJECTS": "Seçili dışındakileri gizle", "HIDEOBJECTS": "Seçilileri gizle", "UNISOLATEOBJECTS": "Gizlenenleri göster",
        "COMMANDLINE": "Komut satırını göster", "COMMANDLINEHIDE": "Komut satırını gizle", "SAVETIME": "Otomatik kaydetme aralığı",
    ]
}
