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
    @IBOutlet weak var progressView: NSProgressIndicator!
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        view.window?.title = "Loading..."
        loadExistingContent()
        startObservingClipboard()
    }
    
    private func setupUI() {
        // Add scroll view
        CoreDataManager.shared.progressHandler = { [weak self] progress in
            guard let self else { return }
            self.progressView.animator().doubleValue = progress
        }
    }
    
    private func loadExistingContent() {
        Task {
            do {
                let items = try await fetchClipboardItems()
                let attributedString = NSMutableAttributedString()
                
                for item in items {
                    await appendClipboardItem(item, to: attributedString)
                }
                
                await MainActor.run {
                    view.window?.title = "Did load \(items.count) items)"
                    textView.textStorage?.setAttributedString(attributedString)
                }
            } catch {
                print("Failed to load existing content:", error)
            }
        }
    }
    
    private func fetchClipboardItems() async throws -> [ClipboardItem] {
        return try await CoreDataManager.shared.fetchClipboardItems()
    }
    
    private func appendClipboardItem(_ item: ClipboardItem, to attributedString: NSMutableAttributedString) async {
        await MainActor.run {
            // Add timestamp
            let timestampAttr = NSAttributedString(
                string: "[\(DateFormatter.localizedString(from: item.timestamp, dateStyle: .short, timeStyle: .medium))]\n",
                attributes: [
                    .foregroundColor: NSColor.systemBlue,
                    .font: NSFont.boldSystemFont(ofSize: 12)
                ]
            )
            attributedString.append(timestampAttr)
            
            // Process contents
            for content in item.contents {
                let type = NSPasteboard.PasteboardType(rawValue: content.typeIdentifier)
                
                // Add type information
                appendTypeInfo(type, to: attributedString)
                
                // Process and add content
                let (contentString, image) = processContent(type, data: content.data)
                appendContent(contentString, to: attributedString)
                
                // Add image preview if available
                if let image = image {
                    appendImagePreview(image, to: attributedString)
                }
            }
            
            // Add spacing
            attributedString.append(NSAttributedString(string: "\n\n"))
        }
    }
    
    private func startObservingClipboard() {
        observationTask = Task {
            let stream = await clipboardObserver.startObserving()
            
            for await clipboardData in stream {
                do {
                    let saved = try await CoreDataManager.shared.saveClipboardData(clipboardData)
                    if saved {
                        handleClipboardContent(clipboardData)
                    }
                } catch {
                    print("Failed to save clipboard data:", error)
                }
            }
        }
    }
    
    private func handleClipboardContent(_ clipboardData: ClipboardData) {
        Task { @MainActor in
            let attributedString = NSMutableAttributedString()
            
            // Add timestamp
            appendTimestamp(to: attributedString)
            
            // Process each type
            for type in clipboardData.types {
                // Add type information
                appendTypeInfo(type, to: attributedString)
                
                // Process and add content
                let (content, image) = processContent(type, data: clipboardData.contents[type])
                appendContent(content, to: attributedString)
                
                // Add image preview if available
                if let image = image {
                    appendImagePreview(image, to: attributedString)
                }
            }
            
            // Add spacing
            attributedString.append(NSAttributedString(string: "\n\n"))
            
            // Combine with existing content
            let existingContent = textView.attributedString()
            attributedString.append(existingContent)
            
            textView.textStorage?.setAttributedString(attributedString)
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
    
    private func processContent(
        _ type: NSPasteboard.PasteboardType,
        data: Data?
    ) -> (String, NSImage?) {
        guard let data = data else {
            return ("No data available", nil)
        }
        
        switch type {
        case .string:
            if let string = String(data: data, encoding: .utf8) {
                return (string, nil)
            }
            return ("Invalid string data", nil)
            
        case .fileURL:
            if let urlString = String(data: data, encoding: .utf8),
               let url = URL(string: urlString) {
                let fileIcon = NSWorkspace.shared.icon(forFile: url.path)
                return ("File: \(url.lastPathComponent)\nPath: \(url.path)", fileIcon)
            }
            return ("Invalid file URL", nil)
            
        case .tiff, .png:
            if let image = NSImage(data: data) {
                return ("Image - Size: \(image.size.width)x\(image.size.height)", image)
            }
            return ("Invalid image data", nil)
            
        case .pdf:
            if let image = NSImage(data: data) {
                return ("PDF content", image)
            }
            return ("PDF data (preview not available)", nil)
            
        case .rtf:
            if let rtfString = NSAttributedString(rtf: data, documentAttributes: nil)?.string {
                return ("RTF content: \(rtfString)", nil)
            }
            return ("Invalid RTF content", nil)
            
        case .html:
            if let htmlString = String(data: data, encoding: .utf8) {
                return ("HTML content: \(htmlString)", nil)
            }
            return ("Invalid HTML content", nil)
            
        case .color:
            if let color = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
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
            if let strings = String(data: data, encoding: .utf8)?.components(separatedBy: "\n") {
                return ("Multiple text selection:\n" + strings.joined(separator: "\n"), nil)
            }
            return ("Invalid multiple text selection", nil)
            
        case .ruler:
            if let paraStyle = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSParagraphStyle.self, from: data) {
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
            if let tabularText = String(data: data, encoding: .utf8) {
                return ("Tabular text:\n\(tabularText)", nil)
            }
            return ("Invalid tabular text", nil)
            
        default:
            return ("[\(type.rawValue)]: \(data.count) bytes", nil)
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

