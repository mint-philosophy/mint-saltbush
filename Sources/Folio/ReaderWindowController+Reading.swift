import AppKit
import CoreImage
import FolioCore
import PDFKit

/// Reading aids: reference previews on hover, exporting highlights and notes, and page themes.
extension ReaderWindowController {
    // MARK: Reference previews

    /// Called as the pointer moves. Hovering on a citation or footnote link for a moment
    /// shows the text it points to, without leaving your place.
    func hover(atViewPoint p: NSPoint) {
        var link: PageAnnotation?
        if pdfView.bounds.contains(p), let page = pdfView.page(for: p, nearest: false),
           let a = page.annotation(at: pdfView.convert(p, to: page)),
           AnnotationKit.kind(a) == "link", ReadingKit.internalDestination(of: a) != nil {
            link = PageAnnotation(a, page)
        }
        guard link?.annotation !== hoveredLink else { return }
        hoveredLink = link?.annotation
        closeLinkPreview()
        guard let link else { return }
        let work = DispatchWorkItem { [weak self] in self?.showLinkPreview(link) }
        previewWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func showLinkPreview(_ link: PageAnnotation) {
        guard let destination = ReadingKit.internalDestination(of: link.annotation),
              let image = ReadingKit.previewImage(of: destination) else { return }
        let imageView = NSImageView(image: themed(image))
        imageView.frame = NSRect(origin: NSPoint(x: 8, y: 8), size: image.size)
        let content = NSView(frame: NSRect(x: 0, y: 0, width: image.size.width + 16, height: image.size.height + 16))
        content.addSubview(imageView)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.show(relativeTo: pdfView.convert(link.annotation.bounds, from: link.page), of: pdfView, preferredEdge: .maxY)
        linkPopover = popover
    }

    func closeLinkPreview() {
        previewWork?.cancel()
        previewWork = nil
        linkPopover?.close()
        linkPopover = nil
    }

    func endHover() {
        hoveredLink = nil
        closeLinkPreview()
    }

    // MARK: Export

    private var exportTitle: String {
        pdfDoc?.fileURL?.deletingPathExtension().lastPathComponent ?? pdfDoc?.displayName ?? "Highlights and notes"
    }

    func copyAnnotations() {
        guard let pdf else { return }
        let summary = ReadingKit.markdownSummary(of: pdf, title: exportTitle)
        guard summary.count > 0 else {
            hud.show("No highlights or notes yet")
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(summary.text, forType: .string)
        hud.show("Copied \(summary.count) highlight\(summary.count == 1 ? "" : "s") and notes as Markdown")
    }

    func exportAnnotations() {
        guard let pdf, let window else { return }
        let summary = ReadingKit.markdownSummary(of: pdf, title: exportTitle)
        guard summary.count > 0 else {
            hud.show("No highlights or notes yet")
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(exportTitle) – highlights.md"
        panel.directoryURL = pdfDoc?.fileURL?.deletingLastPathComponent()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try summary.text.write(to: url, atomically: true, encoding: .utf8)
                self?.hud.show("Exported \(summary.count) items")
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }

    // MARK: Themes

    enum Theme: Int, CaseIterable {
        case normal, sepia, night
        var name: String { ["Normal", "Sepia", "Night"][rawValue] }
    }

    var theme: Theme {
        get { Theme(rawValue: UserDefaults.standard.integer(forKey: "theme")) ?? .normal }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "theme") }
    }

    func cycleTheme() {
        theme = Theme(rawValue: (theme.rawValue + 1) % Theme.allCases.count) ?? .normal
        applyTheme()
        hud.show("\(theme.name) theme")
    }

    /// Themes are Core Image filters over the page view, so they need no re-rendering
    /// and leave the PDF itself untouched.
    func applyTheme() {
        pdfView.wantsLayer = true
        pdfView.layerUsesCoreImageFilters = true
        pdfView.contentFilters = Self.filters(for: theme)
        // Night inverts everything, so start from a light surround to end up with a dark one.
        pdfView.backgroundColor = theme == .night ? NSColor(white: 0.9, alpha: 1) : Self.surround
    }

    static let surround = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.87, alpha: 1)
    }

    static func filters(for theme: Theme) -> [CIFilter] {
        func matrix(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, bias: CGFloat = 0) -> CIFilter {
            let f = CIFilter(name: "CIColorMatrix")!
            f.setDefaults()
            f.setValue(CIVector(x: r, y: 0, z: 0, w: 0), forKey: "inputRVector")
            f.setValue(CIVector(x: 0, y: g, z: 0, w: 0), forKey: "inputGVector")
            f.setValue(CIVector(x: 0, y: 0, z: b, w: 0), forKey: "inputBVector")
            f.setValue(CIVector(x: bias, y: bias, z: bias, w: 0), forKey: "inputBiasVector")
            return f
        }
        switch theme {
        case .normal:
            return []
        case .sepia:
            // White paper becomes warm cream; black text stays black.
            return [matrix(1, 0.94, 0.82)]
        case .night:
            // Invert in perceptual (sRGB) space so light highlights become dark ones, turn hues back
            // round so highlight colours stay recognisable, then soften the contrast.
            let invert = CIFilter(name: "CIColorInvert")!
            let hue = CIFilter(name: "CIHueAdjust")!
            hue.setValue(CGFloat.pi, forKey: kCIInputAngleKey)
            let toPerceptual = CIFilter(name: "CILinearToSRGBToneCurve")!
            let toLinear = CIFilter(name: "CISRGBToneCurveToLinear")!
            // In linear light these give roughly an 11% grey page and 90% grey text.
            return [toPerceptual, invert, hue, toLinear, matrix(0.76, 0.76, 0.76, bias: 0.012)]
        }
    }

    /// Applies the current theme to an image shown outside the page view, such as a reference preview.
    func themed(_ image: NSImage) -> NSImage {
        let filters = Self.filters(for: theme)
        guard !filters.isEmpty, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        var output = CIImage(cgImage: cg)
        for f in filters {
            f.setValue(output, forKey: kCIInputImageKey)
            output = f.outputImage ?? output
        }
        let rep = NSCIImageRep(ciImage: output)
        let result = NSImage(size: image.size)
        result.addRepresentation(rep)
        return result
    }
}
