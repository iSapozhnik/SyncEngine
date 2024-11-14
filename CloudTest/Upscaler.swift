import Metal
import MetalKit
import AppKit

class MetalUpscaler {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let defaultLibrary: MTLLibrary
    private let pipelineState: MTLComputePipelineState
    
    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let defaultLibrary = try? device.makeDefaultLibrary(),
              let kernelFunction = defaultLibrary.makeFunction(name: "upscaleKernel"),
              let pipelineState = try? device.makeComputePipelineState(function: kernelFunction) else {
            return nil
        }
        
        self.device = device
        self.commandQueue = commandQueue
        self.defaultLibrary = defaultLibrary
        self.pipelineState = pipelineState
    }
    
    func upscale(texture: MTLTexture, scale: Int) -> MTLTexture? {
        let width = texture.width * scale
        let height = texture.height * scale
        
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: texture.pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        guard let outputTexture = device.makeTexture(descriptor: descriptor),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return nil
        }
        
        computeEncoder.setComputePipelineState(pipelineState)
        computeEncoder.setTexture(texture, index: 0)
        computeEncoder.setTexture(outputTexture, index: 1)
        
        let threadGroupSize = MTLSize(width: 16, height: 16, depth: 1)
        let threadGroups = MTLSize(
            width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        return outputTexture
    }
    
    func upscale(image: NSImage, scale: Int) -> NSImage? {
        // Convert NSImage to CGImage with correct orientation
        guard let cgImage = convertToCGImage(image) else { return nil }
        
        // Create texture from CGImage
        let textureLoader = MTKTextureLoader(device: device)
        let textureLoaderOptions: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .origin: MTKTextureLoader.Origin.topLeft
        ]
        
        guard let inputTexture = try? textureLoader.newTexture(
            cgImage: cgImage,
            options: textureLoaderOptions
        ) else { return nil }
        
        // Perform upscaling
        guard let outputTexture = upscale(texture: inputTexture, scale: scale) else {
            return nil
        }
        
        // Convert back to NSImage
        guard let ciImage = CIImage(mtlTexture: outputTexture, options: [
            .colorSpace: CGColorSpaceCreateDeviceRGB()
        ]) else { return nil }
        
        let context = CIContext(options: nil)
        guard let outputCGImage = context.createCGImage(
            ciImage,
            from: ciImage.extent,
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else { return nil }
        
        return NSImage(cgImage: outputCGImage, size: NSSize(
            width: outputCGImage.width,
            height: outputCGImage.height
        ))
    }
    
    private func convertToCGImage(_ image: NSImage) -> CGImage? {
        let imageRect = NSRect(origin: .zero, size: image.size)
        
        guard let imageRef = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        
        guard let context = CGContext(data: nil,
                                    width: Int(imageRect.width),
                                    height: Int(imageRect.height),
                                    bitsPerComponent: 8,
                                    bytesPerRow: 0,
                                    space: colorSpace,
                                    bitmapInfo: bitmapInfo) else {
            return nil
        }
        
        // Flip the context coordinate system
        context.translateBy(x: 0, y: imageRect.height)
        context.scaleBy(x: 1.0, y: -1.0)
        
        context.draw(imageRef, in: imageRect)
        return context.makeImage()
    }
}

// Metal Shader (save as "Shaders.metal" in your project)
/*
#include <metal_stdlib>
using namespace metal;

kernel void upscaleKernel(texture2d<float, access::sample> inputTexture [[texture(0)]],
                         texture2d<float, access::write> outputTexture [[texture(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    constexpr sampler textureSampler(filter::linear);
    
    float2 inputSize = float2(inputTexture.get_width(), inputTexture.get_height());
    float2 outputSize = float2(outputTexture.get_width(), outputTexture.get_height());
    float2 texCoord = float2(gid) / outputSize;
    
    float4 color = inputTexture.sample(textureSampler, texCoord);
    outputTexture.write(color, gid);
}
*/

// Example usage in AppKit
class ImageUpscalingViewController: NSViewController {
    private let upscaler = MetalUpscaler()
    private let imageView = NSImageView()
    let savePanel = NSOpenPanel()

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        // Setup image view
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        
        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: view.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        
        // Add upscale button
        let upscaleButton = NSButton(title: "Upscale Image", target: self, action: #selector(upscaleImage))
        upscaleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(upscaleButton)
        
        NSLayoutConstraint.activate([
            upscaleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            upscaleButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20)
        ])
    }
    
    @objc private func upscaleImage() {
        let openPanel = NSOpenPanel()
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.canChooseFiles = true
        openPanel.allowedContentTypes = [.image]
        
        openPanel.beginSheetModal(for: view.window!) { response in
            guard response == .OK,
                  let url = openPanel.url,
                  let image = NSImage(contentsOf: url),
                  let upscaler = self.upscaler,
                  let upscaledImage = upscaler.upscale(image: image, scale: 4) else {
                return
            }
            
            self.imageView.image = upscaledImage
            
            // Optional: Save the upscaled image
            self.saveUpscaledImage(upscaledImage)
        }
    }
    
    private func saveUpscaledImage(_ image: NSImage) {
        savePanel.allowedContentTypes = [.png]
        savePanel.nameFieldStringValue = "upscaled_image.png"
        
        savePanel.beginSheetModal(for: view.window!) { response in
            guard response == .OK,
                  let url = self.savePanel.url,
                  let tiffData = image.tiffRepresentation,
                  let bitmapImage = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmapImage.representation(using: .png, properties: [:]) else {
                return
            }
            
            try? pngData.write(to: url)
        }
    }
}

class ImageUpscalerWindowController: NSWindowController {
    convenience init() {
        // Create a window
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Image Upscaler"
        window.center()
        window.minSize = NSSize(width: 400, height: 300)
        
        // Set up the content view controller
        let contentViewController = ImageUpscalingViewController()
        window.contentViewController = contentViewController
        
        self.init(window: window)
    }
}

class MainViewController: NSViewController {
    private var upscalerWindowController: ImageUpscalerWindowController?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }
    
    private func setupUI() {
        let upscaleButton = NSButton(title: "Open Upscaler", target: self, action: #selector(showUpscaler))
        upscaleButton.bezelStyle = .rounded
        upscaleButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(upscaleButton)
        
        NSLayoutConstraint.activate([
            upscaleButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            upscaleButton.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    
    @objc private func showUpscaler() {
        if upscalerWindowController == nil {
            upscalerWindowController = ImageUpscalerWindowController()
        }
        
        upscalerWindowController?.showWindow(nil)
        upscalerWindowController?.window?.makeKeyAndOrderFront(nil)
    }
    
    // Clean up window controller when view controller is deallocated
    deinit {
        upscalerWindowController = nil
    }
}
