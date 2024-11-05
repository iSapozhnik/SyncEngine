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
        let pasteboard = NSPasteboard.general
        
        var pasteboardImage: NSImage? = nil
        pasteboardItem.types.forEach { type in
            let content: String

            switch type {
            case .string:
                content = pasteboard.string(forType: .string) ?? "No string content"
            case .fileURL:
                content = pasteboard.string(forType: .fileURL) ?? "No file URL content"
            case .tiff:
                if let imageData = pasteboard.data(forType: .tiff),
                   let image = NSImage(data: imageData) {
                    content = "[Image preview below]"
                    pasteboardImage = image
                } else {
                    content = "Invalid TIFF image data"
                }
            case .png:
                if let imageData = pasteboard.data(forType: .png),
                   let image = NSImage(data: imageData) {
                    content = "[Image preview below]"
                    pasteboardImage = image
                } else {
                    content = "Invalid PNG image data"
                }
            default:
                content = "Unsupported content type: \(type.rawValue)"
            }
            
            DispatchQueue.main.async { [weak self] in
                let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
                
                let attributedString = NSMutableAttributedString()
                
                // Timestamp with blue color and bold
                let timestampAttr = NSAttributedString(
                    string: "[\(timestamp)]\n",
                    attributes: [
                        .foregroundColor: NSColor.systemBlue,
                        .font: NSFont.boldSystemFont(ofSize: 12)
                    ]
                )
                attributedString.append(timestampAttr)
                
                // Type with purple color
                let typeAttr = NSAttributedString(
                    string: "Type: ",
                    attributes: [
                        .foregroundColor: NSColor.systemPurple,
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                    ]
                )
                attributedString.append(typeAttr)
                
                // Type value with dark gray
                let typeValueAttr = NSAttributedString(
                    string: "\(type.rawValue)\n",
                    attributes: [
                        .foregroundColor: NSColor.lightGray,
                        .font: NSFont.systemFont(ofSize: 12)
                    ]
                )
                attributedString.append(typeValueAttr)
                
                // Content label with green color
                let contentLabelAttr = NSAttributedString(
                    string: "Content: ",
                    attributes: [
                        .foregroundColor: NSColor.systemGreen,
                        .font: NSFont.systemFont(ofSize: 12, weight: .medium)
                    ]
                )
                attributedString.append(contentLabelAttr)
                
                // Content value with default text color
                let contentValueAttr = NSAttributedString(
                    string: "\(content)\n",
                    attributes: [
                        .foregroundColor: NSColor.labelColor,
                        .font: NSFont.systemFont(ofSize: 12)
                    ]
                )
                attributedString.append(contentValueAttr)
                
                // Add image if present
                if let image = pasteboardImage {
                    // Resize image if too large
                    let maxWidth: CGFloat = 300
                    let maxHeight: CGFloat = 200
                    let resizedImage = self?.resizeImage(image, maxWidth: maxWidth, maxHeight: maxHeight)
                    
                    if let attachment = NSTextAttachment() as? NSTextAttachment {
                        attachment.image = resizedImage
                        let imageString = NSAttributedString(attachment: attachment)
                        attributedString.append(imageString)
                        attributedString.append(NSAttributedString(string: "\n"))
                    }
                }
                
                // Add extra newline
                attributedString.append(NSAttributedString(string: "\n"))
                
                // Combine with existing content
                if let existingContent = self?.textView.attributedString() {
                    attributedString.append(existingContent)
                }
                
                self?.textView.textStorage?.setAttributedString(attributedString)
            }
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

