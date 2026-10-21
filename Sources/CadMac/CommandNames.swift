import Foundation

/// Command input in other languages. Every name below is accepted whatever the UI language is;
/// English names and aliases always win. Typing with a Georgian or Russian keyboard layout also
/// works: "ლ" / "д" (the L key) is read as L.
enum CommandNames {
    /// Canonical command → localized names (Turkish, Georgian). One word each, since Space submits.
    static let localized: [String: [String]] = [
        "LINE": ["ÇİZGİ", "ხაზი"], "PLINE": ["ÇOKLUÇİZGİ", "პოლიხაზი"], "RECTANG": ["DİKDÖRTGEN", "მართკუთხედი"],
        "CIRCLE": ["DAİRE", "წრე"], "ARC": ["YAY", "რკალი"], "ELLIPSE": ["ELİPS", "ელიფსი"], "POLYGON": ["ÇOKGEN", "მრავალკუთხედი"],
        "POINT": ["NOKTA", "წერტილი"], "SPLINE": ["EĞRİ", "სპლაინი"], "DONUT": ["HALKA", "რგოლი"], "XLINE": ["YARDIMCIÇİZGİ", "დამხმარეხაზი"],
        "RAY": ["IŞIN", "სხივი"], "REVCLOUD": ["BULUT", "ღრუბელი"], "HATCH": ["TARAMA", "დაშტრიხვა"], "TEXT": ["YAZI", "ტექსტი"],
        "MTEXT": ["ÇOKSATIRYAZI", "მტექსტი"],
        "ERASE": ["SİL", "წაშლა"], "MOVE": ["TAŞI", "გადატანა"], "COPY": ["KOPYALA", "კოპირება", "ასლი"], "ROTATE": ["DÖNDÜR", "მობრუნება"],
        "SCALE": ["ÖLÇEKLE", "მასშტაბი"], "MIRROR": ["AYNALA", "სარკე"], "STRETCH": ["ESNET", "გაჭიმვა"], "OFFSET": ["ÖTELE", "ოფსეტი", "პარალელი"],
        "TRIM": ["KIRP", "მოჭრა"], "EXTEND": ["UZAT", "გაგრძელება"], "FILLET": ["YUVARLA", "მომრგვალება"], "CHAMFER": ["PAHKIR", "ფასკა"],
        "BREAK": ["KES", "გაწყვეტა"], "JOIN": ["BİRLEŞTİR", "შეერთება"], "EXPLODE": ["PATLAT", "დაშლა"], "LENGTHEN": ["UZUNLUK", "დაგრძელება"],
        "ARRAY": ["DİZİ", "მასივი"], "MATCHPROP": ["ÖZELLİKEŞLE", "თვისებებისგადატანა"], "DIVIDE": ["EŞİTBÖL", "დაყოფა"],
        "MEASURE": ["ARALIKLABÖL", "ბიჯითდაყოფა"],
        "DIMLINEAR": ["DOĞRUSALÖLÇÜ", "ხაზოვანიზომა"], "DIMALIGNED": ["HİZALIÖLÇÜ", "გასწორებულიზომა"], "DIMRADIUS": ["YARIÇAPÖLÇÜ", "რადიუსი"],
        "DIMDIAMETER": ["ÇAPÖLÇÜ", "დიამეტრი"], "DIMANGULAR": ["AÇIÖLÇÜ", "კუთხურიზომა"], "DIMCONTINUE": ["ZİNCİRÖLÇÜ", "ჯაჭვურიზომა"],
        "DIMBASELINE": ["TABANÖLÇÜ", "საბაზოზომა"], "QLEADER": ["OKYAZI", "გამომყვანი"],
        "BLOCK": ["BLOK", "ბლოკი"], "INSERT": ["BLOKEKLE", "ჩასმა"], "BEDIT": ["BLOKDÜZENLE", "ბლოკისრედაქტორი"], "LAYOUT": ["ლეიაუტი"],
        "DIST": ["MESAFE", "მანძილი"], "AREA": ["ALAN", "ფართობი"], "ID": ["KOORDİNAT", "კოორდინატი"], "UNITS": ["BİRİM", "ერთეულები"],
        "LIST": ["LİSTELE", "სია"], "ZOOM": ["YAKINLAŞTIR", "ზუმი"], "REGEN": ["YENİLE", "განახლება"], "PAN": ["KAYDIR", "პანი"],
        "LAYER": ["KATMAN", "შრე", "შრეები"], "PROPERTIES": ["ÖZELLİKLER", "თვისებები"], "UNDO": ["GERİAL", "გაუქმება"], "REDO": ["YİNELE", "დაბრუნება"],
        "PURGE": ["TEMİZLE", "გასუფთავება"], "SELECTALL": ["TÜMÜNÜSEÇ", "ყველა"], "PLOT": ["YAZDIR", "ბეჭდვა"], "EXPORTPDF": ["PDFAKTAR", "პდფ"],
        "ORTHO": ["ორთო"], "GRID": ["IZGARA", "ბადე"], "SNAP": ["YAKALA", "ბიჯი"], "OSNAP": ["NESNEYAKALAMA", "მიბმა"],
        "HELP": ["YARDIM", "დახმარება"], "COMMANDS": ["KOMUTLAR", "ბრძანებები"], "CHAT": ["SOHBET", "ჩატი"],
        "CROSSHAIR": ["ARTIİMLEÇ", "ჯვარედინი"],
        "QSELECT": ["HIZLISEÇ", "სწრაფიარჩევა"], "ALIGN": ["HİZALA", "გასწორება"], "DRAWORDER": ["ÇİZİMSIRASI", "რიგი"],
        "GROUP": ["GRUP", "ჯგუფი"], "UNGROUP": ["GRUPÇÖZ", "ჯგუფისდაშლა"], "OVERKILL": ["ÇİFTTEMİZLE", "დუბლიკატები"],
        "COUNT": ["SAY", "დათვლა"], "FIND": ["BUL", "ძებნა"],
    ]

    /// Localized names to show in the current UI language (none for English).
    @MainActor static func names(for command: String) -> [String] {
        let all = localized[command] ?? []
        let georgian = { (s: String) in s.unicodeScalars.contains { (0x10A0...0x10FF).contains($0.value) } }
        switch Loc.lang {
        case .en: return []
        case .tr: return all.filter { !georgian($0) }
        case .ka: return all.filter(georgian)
        }
    }

    /// Folds case and Turkish diacritics so "çizgi", "ÇİZGİ" and "CIZGI" all match.
    static func normalize(_ s: String) -> String {
        s.uppercased().folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Normalized localized name → canonical command name.
    static let index: [String: String] = {
        var d: [String: String] = [:]
        for (cmd, names) in localized { for n in names { d[normalize(n)] = cmd } }
        return d
    }()

    /// Characters typed with a non-Latin keyboard layout → the Latin key in the same position.
    private static let layoutMap: [Character: Character] = {
        var m: [Character: Character] = [:]
        // Georgian (QWERTY based); Shift letters map to the same key.
        let ka = Array("ქწერტყუიოპასდფგჰჯკლზხცვბნმ"), kaLatin = Array("QWERTYUIOPASDFGHJKLZXCVBNM")
        for (k, l) in zip(ka, kaLatin) { m[k] = l }
        for (k, l) in zip(Array("ჭღთშჟძჩ"), Array("WRTSJZC")) { m[k] = l }
        // Russian ЙЦУКЕН.
        let ru = Array("йцукенгшщзфывапролдячсмитьЙЦУКЕНГШЩЗФЫВАПРОЛДЯЧСМИТЬ")
        let ruLatin = Array("QWERTYUIOPASDFGHJKLZXCVBNMQWERTYUIOPASDFGHJKLZXCVBNM")
        for (k, l) in zip(ru, ruLatin) { m[k] = l }
        return m
    }()

    /// Re-reads text typed with a Georgian/Russian layout as Latin keys; nil when nothing changes.
    static func fromKeyboardLayout(_ s: String) -> String? {
        var changed = false
        let out = String(s.map { ch -> Character in
            var c = ch
            // Mtavruli (Georgian capitals) → Mkhedruli.
            if let u = ch.unicodeScalars.first, ch.unicodeScalars.count == 1, (0x1C90...0x1CBF).contains(u.value),
               let lower = Unicode.Scalar(u.value - 0x1C90 + 0x10D0) { c = Character(lower) }
            if let l = layoutMap[c] { changed = true; return l }
            return ch
        })
        return changed ? out : nil
    }
}
