//
//  ViewController.swift
//  CloudTest
//
//  Created by Ivan Sapozhnik on 05.11.24.
//

import Cocoa

class ViewController: NSViewController {
    private let clipboardObserver = ClipboardObserver()
    private var observationTask: Task<Void, Never>?
    
    @IBOutlet var textView: NSTextView!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        startObservingClipboard()
    }
    
    private func setupUI() {
        // Add scroll view

    }
    
    private func startObservingClipboard() {
        observationTask = Task {
            let stream = await clipboardObserver.startObserving()
            
            for await pasteboardItem in stream {
                handleClipboardContent(pasteboardItem)
            }
        }
    }
    
    private func handleClipboardContent(_ pasteboardItem: NSPasteboardItem) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            let attributedString = NSMutableAttributedString()
            
            // Add timestamp
            self.appendTimestamp(to: attributedString)
            
            // Process each type in the pasteboard item
            pasteboardItem.types.forEach { type in
                // Add type information
                self.appendTypeInfo(type, to: attributedString)
                
                // Process and add content
                let (content, image) = self.processContent(for: type)
                self.appendContent(content, to: attributedString)
                
                // Add image preview if available
                if let image = image {
                    self.appendImagePreview(image, to: attributedString)
                }
            }
            
            // Add spacing
            attributedString.append(NSAttributedString(string: "\n\n"))
            
            // Combine with existing content
            let existingContent = self.textView.attributedString()
            attributedString.append(existingContent)
            
            self.textView.textStorage?.setAttributedString(attributedString)
        }
    }
    
    private func appendTimestamp(to attributedString: NSMutableAttributedString) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let timestampAttr = NSAttributedString(
            string: "[\(timestamp)]\n",
            attributes: [
                .foregroundColor: NSColor.systemBlue,
                .font: NSFont.boldSystemFont(ofSize: 12)
            ]
        )
        attributedString.append(timestampAttr)
    }
    
    private func appendTypeInfo(_ type: NSPasteboard.PasteboardType, to attributedString: NSMutableAttributedString) {
        let typeLabel = NSAttributedString(
            string: "Type: ",
            attributes: [
                .foregroundColor: NSColor.systemPurple,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )
        attributedString.append(typeLabel)
        
        let typeValue = NSAttributedString(
            string: "\(type.rawValue)\n",
            attributes: [
                .foregroundColor: NSColor.lightGray,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributedString.append(typeValue)
    }
    
    private func processContent(for type: NSPasteboard.PasteboardType) -> (String, NSImage?) {
        let pasteboard = NSPasteboard.general
        
        switch type {
        case .string:
            return (pasteboard.string(forType: .string) ?? "No string content", nil)
        
        case .fileURL:
            if let urlString = pasteboard.string(forType: .fileURL),
               let url = URL(string: urlString) {
                let fileIcon = NSWorkspace.shared.icon(forFile: url.path)
                return ("File: \(url.lastPathComponent)\nPath: \(url.path)", fileIcon)
            }
            return ("No file URL content", nil)
        
        case .URL:
            if let urlString = pasteboard.string(forType: .URL),
               let url = URL(string: urlString) {
                return ("URL: \(url.absoluteString)", nil)
            }
            return ("Invalid URL", nil)
        
        case .tiff:
            if let imageData = pasteboard.data(forType: .tiff),
               let image = NSImage(data: imageData) {
                return ("Image (TIFF) - Size: \(image.size.width)x\(image.size.height)", image)
            }
            return ("Invalid TIFF image data", nil)
        
        case .png:
            if let imageData = pasteboard.data(forType: .png),
               let image = NSImage(data: imageData) {
                return ("Image (PNG) - Size: \(image.size.width)x\(image.size.height)", image)
            }
            return ("Invalid PNG image data", nil)
        
        case .pdf:
            if let pdfData = pasteboard.data(forType: .pdf),
               let image = NSImage(data: pdfData) {
                return ("PDF content", image)
            }
            return ("PDF data (preview not available)", nil)
        
        case .rtf:
            if let rtfData = pasteboard.data(forType: .rtf),
               let rtfString = NSAttributedString(rtf: rtfData, documentAttributes: nil)?.string {
                return ("RTF content: \(rtfString)", nil)
            }
            return ("Invalid RTF content", nil)
        
        case .html:
            if let htmlString = pasteboard.string(forType: .html) {
                return ("HTML content: \(htmlString)", nil)
            }
            return ("Invalid HTML content", nil)
        
        case .color:
            if let colorData = pasteboard.data(forType: .color),
               let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: colorData) {
                let colorPreview = NSImage(size: NSSize(width: 20, height: 20))
                colorPreview.lockFocus()
                color.drawSwatch(in: NSRect(x: 0, y: 0, width: 20, height: 20))
                colorPreview.unlockFocus()
                
                // Add color components information
                var colorInfo = "Color"
                if let calibratedColor = color.usingColorSpace(.genericRGB) {
                    colorInfo += String(format: "\nRGB: (%.2f, %.2f, %.2f, %.2f)",
                                      calibratedColor.redComponent,
                                      calibratedColor.greenComponent,
                                      calibratedColor.blueComponent,
                                      calibratedColor.alphaComponent)
                }
                return (colorInfo, colorPreview)
            }
            return ("Invalid color data", nil)
        
        case .multipleTextSelection:
            if let strings = pasteboard.propertyList(forType: .multipleTextSelection) as? [String] {
                return ("Multiple text selection:\n" + strings.joined(separator: "\n"), nil)
            }
            return ("Invalid multiple text selection", nil)
        
        case .ruler:
            if let rulerData = pasteboard.data(forType: .ruler),
               let paraStyle = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSParagraphStyle.self, from: rulerData) {
                let attributes = [
                    "First line head indent: \(paraStyle.firstLineHeadIndent)",
                    "Head indent: \(paraStyle.headIndent)",
                    "Tail indent: \(paraStyle.tailIndent)",
                    "Line spacing: \(paraStyle.lineSpacing)",
                    "Alignment: \(paraStyle.alignment.rawValue)"
                ]
                return ("Ruler data:\n" + attributes.joined(separator: "\n"), nil)
            }
            return ("Invalid ruler data", nil)
        
        case .tabularText:
            if let tabularText = pasteboard.string(forType: .tabularText) {
                return ("Tabular text:\n\(tabularText)", nil)
            }
            return ("Invalid tabular text", nil)
        
        default:
            // Try to get string representation for unknown types
            if let string = pasteboard.string(forType: type) {
                return ("[\(type.rawValue)]: \(string)", nil)
            }
            
            // Try to get data representation
            if let data = pasteboard.data(forType: type) {
                return ("[\(type.rawValue)]: \(data.count) bytes of data", nil)
            }
            
            return ("Unsupported content type: \(type.rawValue)", nil)
        }
    }
    
    private func appendContent(_ content: String, to attributedString: NSMutableAttributedString) {
        let contentLabel = NSAttributedString(
            string: "Content: ",
            attributes: [
                .foregroundColor: NSColor.systemGreen,
                .font: NSFont.systemFont(ofSize: 12, weight: .medium)
            ]
        )
        attributedString.append(contentLabel)
        
        let contentValue = NSAttributedString(
            string: "\(content)\n",
            attributes: [
                .foregroundColor: NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 12)
            ]
        )
        attributedString.append(contentValue)
    }
    
    private func appendImagePreview(_ image: NSImage, to attributedString: NSMutableAttributedString) {
        let maxWidth: CGFloat = 300
        let maxHeight: CGFloat = 200
        let resizedImage = resizeImage(image, maxWidth: maxWidth, maxHeight: maxHeight)
        
        if let attachment = NSTextAttachment() as? NSTextAttachment {
            attachment.image = resizedImage
            let imageString = NSAttributedString(attachment: attachment)
            attributedString.append(imageString)
            attributedString.append(NSAttributedString(string: "\n"))
        }
    }
    
    private func resizeImage(_ image: NSImage, maxWidth: CGFloat, maxHeight: CGFloat) -> NSImage {
        let sourceWidth = image.size.width
        let sourceHeight = image.size.height
        
        var targetWidth = sourceWidth
        var targetHeight = sourceHeight
        
        if sourceWidth > maxWidth {
            targetWidth = maxWidth
            targetHeight = targetWidth * sourceHeight / sourceWidth
        }
        
        if targetHeight > maxHeight {
            targetHeight = maxHeight
            targetWidth = targetHeight * sourceWidth / sourceHeight
        }
        
        let resizedImage = NSImage(size: NSSize(width: targetWidth, height: targetHeight))
        resizedImage.lockFocus()
        image.draw(in: NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
                   from: NSRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight),
                   operation: .copy,
                   fraction: 1.0)
        resizedImage.unlockFocus()
        
        return resizedImage
    }
    
    deinit {
        observationTask?.cancel()
    }
}

