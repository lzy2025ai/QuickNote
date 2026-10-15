import AppKit
import ImageIO
import SwiftUI
import Vision

/// 图片缩略图（带缓存，避免列表滚动时反复解码大图）
enum ImageLoader {
    private static let cache = NSCache<NSString, NSImage>()

    static func cached(_ url: URL, maxPixel: Int) -> NSImage? {
        cache.object(forKey: key(url, maxPixel))
    }

    /// 同步解码；只在后台线程调用（见 ThumbnailView）
    static func thumbnail(_ url: URL, maxPixel: Int = 320) -> NSImage? {
        if let cached = cached(url, maxPixel: maxPixel) { return cached }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // iCloud 里还没下载到本机的附件
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: .zero)
        cache.setObject(image, forKey: key(url, maxPixel))
        return image
    }

    private static func key(_ url: URL, _ maxPixel: Int) -> NSString {
        "\(url.path)#\(maxPixel)" as NSString
    }
}

/// 缩略图在后台解码后淡入显示，滚动列表时不阻塞界面
struct ThumbnailView: View {
    let url: URL
    var maxPixel = 320
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Rectangle().fill(Color.primary.opacity(0.04))
            }
        }
        .task(id: "\(url.path)#\(maxPixel)") {
            if let cached = ImageLoader.cached(url, maxPixel: maxPixel) {
                image = cached
                return
            }
            let url = self.url, maxPixel = self.maxPixel
            let loaded = await Task.detached(priority: .utility) {
                ImageLoader.thumbnail(url, maxPixel: maxPixel)
            }.value
            withAnimation(Motion.quick) { image = loaded }
        }
    }
}

/// 用系统自带的 Vision 识别图片里的文字（支持中英文），让截图也能被搜索到
enum TextRecognizer {
    static func recognize(_ url: URL, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(url: url)
            try? handler.perform([request])
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}

extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
