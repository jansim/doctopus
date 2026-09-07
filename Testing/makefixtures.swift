import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

struct Doc { let folder: String; let name: String; let lines: [String]; let raster: Bool }

let docs: [Doc] = [
    Doc(folder: "Inbox", name: "IMG_4821.pdf", lines: [
        "Stadtwerke München GmbH", "Emmy-Noether-Straße 2, 80992 München", "",
        "RECHNUNG", "Rechnungsnummer: 2026-114552", "Rechnungsdatum: 14.01.2026",
        "Kundennummer: 88213", "", "Stromlieferung 01.12.2025 – 31.12.2025",
        "Verbrauch: 284 kWh", "", "Gesamtbetrag: 128,40 EUR",
        "Zahlbar innerhalb von 14 Tagen.", "", "Mit freundlichen Grüßen",
    ], raster: false),
    Doc(folder: "Inbox", name: "scan 003.pdf", lines: [
        "Northwind Insurance Ltd", "44 Bishopsgate, London EC2N 4AY", "",
        "INSURANCE POLICY SCHEDULE", "Policy Number: NW-772-1180",
        "Date: 3 March 2026", "Insured: J. Simson", "",
        "Cover: Household contents and personal possessions",
        "Annual premium: £412.00", "Renewal date: 3 March 2027",
        "", "Please retain this document for your records.",
    ], raster: true),
    Doc(folder: "Finances/Statements", name: "kontoauszug-2026-02.pdf", lines: [
        "Deutsche Bank AG", "", "Kontoauszug Nr. 2 / 2026",
        "IBAN: DE89 3704 0044 0532 0130 00", "Datum: 28.02.2026", "",
        "Opening balance: 4.219,88 EUR", "Closing balance: 3.884,12 EUR",
        "", "12.02.2026  Stadtwerke München    -128,40",
        "18.02.2026  Rewe Markt              -84,21",
    ], raster: false),
    Doc(folder: "Work", name: "Gehaltsabrechnung Februar 2026.pdf", lines: [
        "Acme Robotics GmbH", "Personalabteilung", "",
        "GEHALTSABRECHNUNG", "Abrechnungsmonat: Februar 2026",
        "Datum: 25.02.2026", "", "Bruttogehalt: 6.400,00 EUR",
        "Net pay: 3.812,45 EUR", "Steuerklasse: 1",
    ], raster: false),
    Doc(folder: "Inbox", name: "document(2).pdf", lines: [
        "Finanzamt München Abteilung III", "", "STEUERBESCHEID 2025",
        "Steuernummer: 143/812/40021", "Datum: 07.04.2026", "",
        "Festgesetzte Einkommensteuer: 14.882,00 EUR",
        "Bereits geleistet: 15.940,00 EUR", "Erstattung: 1.058,00 EUR",
    ], raster: true),
    Doc(folder: "Personal", name: "Lease Agreement.pdf", lines: [
        "Hausverwaltung Kranz KG", "", "RENTAL AGREEMENT / MIETVERTRAG",
        "Agreement dated 1 September 2025", "",
        "The parties hereby agree to the following terms and conditions.",
        "Monthly rent: 1.480,00 EUR", "Deposit: 4.440,00 EUR",
    ], raster: false),
]

func drawPage(_ ctx: CGContext, _ lines: [String], raster: Bool) {
    let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)

    let render: (CGContext, CGFloat) -> Void = { c, scale in
        c.setFillColor(gray: 1, alpha: 1)
        c.fill(CGRect(origin: .zero, size: CGSize(width: pageRect.width * scale, height: pageRect.height * scale)))
        let nsCtx = NSGraphicsContext(cgContext: c, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        var y = pageRect.height - 90
        for (i, line) in lines.enumerated() {
            let bold = i == 3 || (i == 0)
            let font = NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: (bold ? 15 : 11) * 1)!
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let s = line as NSString
            c.saveGState()
            c.scaleBy(x: scale, y: scale)
            s.draw(at: NSPoint(x: 64, y: y), withAttributes: attrs)
            c.restoreGState()
            y -= (bold ? 26 : 17)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    if raster {
        // No text layer at all — exactly what a Continuity Camera scan produces.
        let scale: CGFloat = 2
        let w = Int(pageRect.width * scale), h = Int(pageRect.height * scale)
        let bmp = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        render(bmp, scale)
        let img = bmp.makeImage()!
        ctx.draw(img, in: pageRect)
    } else {
        render(ctx, 1)
    }
}

for doc in docs {
    let dir = out.appendingPathComponent(doc.folder, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(doc.name)
    var media = CGRect(x: 0, y: 0, width: 595, height: 842)
    guard let ctx = CGContext(url as CFURL, mediaBox: &media, nil) else { continue }
    ctx.beginPage(mediaBox: &media)
    drawPage(ctx, doc.lines, raster: doc.raster)
    ctx.endPage()
    ctx.closePDF()
    print("wrote \(doc.folder)/\(doc.name)")
}
