import Foundation
import Testing
@testable import CadCore

/// Geçici repro: büyük DWG açmada DWG→DXF çözme vs DXF→Drawing parse sürelerini ayırır.
@Suite("repro: büyük DWG açma")
struct ReproLargeTests {
    private func phases(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { print("YOK: \(path)"); return }
        let url = URL(fileURLWithPath: path)
        let data = (try? Data(contentsOf: url)) ?? Data()
        let name = url.lastPathComponent
        do {
            let t0 = Date()
            let dxf = try NativeDWGReader.convertToDXF(data: data)
            let tDecode = Date().timeIntervalSince(t0)
            let t1 = Date()
            _ = try DXFReader.read(data: dxf)
            let tParse = Date().timeIntervalSince(t1)
            print(String(format: "%-26@ %5.1fMB  DWG→DXF %6.2fs  DXF(%4.1fMB)→Drawing %6.2fs  TOPLAM %6.2fs",
                         name as NSString, Double(data.count)/1e6, tDecode,
                         Double(dxf.count)/1e6, tParse, tDecode + tParse))
        } catch {
            print("FAIL \(name): \(error)")
        }
    }

    @Test func sitePlan()  { phases("/Users/nikasert/Desktop/Artan Property/3d/Magnetic - Site Plan.dwg") }
    @Test func block01()   { phases("/Users/nikasert/Desktop/Artan Property/3d/Magnetic - BLOCK 01.dwg") }
}
