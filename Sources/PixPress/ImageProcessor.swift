import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import Accelerate
import CWebPShim
import CMozJPEGShim

// MARK: - Output formats

enum OutputFormat: String, CaseIterable, Identifiable {
    case webp
    case jpeg
    case png
    case heic
    case avif
    case original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .webp: return "WebP"
        case .jpeg: return "JPEG"
        case .png: return "PNG"
        case .heic: return "HEIC"
        case .avif: return "AVIF"
        case .original: return "Format d'origine"
        }
    }

    var fileExtension: String {
        switch self {
        case .webp: return "webp"
        case .jpeg: return "jpg"
        case .png: return "png"
        case .heic: return "heic"
        case .avif: return "avif"
        case .original: return "" // resolved from the input
        }
    }

    /// Whether the lossy-quality slider applies to this format.
    var usesQuality: Bool {
        switch self {
        case .jpeg, .webp, .heic, .avif: return true
        case .png, .original: return false
        }
    }

    var supportsLossless: Bool { self == .webp }

    /// The output format matching a file extension, or nil when the extension
    /// has no exact re-encodable output (e.g. tiff/gif/bmp) — callers must not
    /// treat those as "same format" for in-place overwrite.
    static func from(extension ext: String) -> OutputFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg", "jpe": return .jpeg
        case "png": return .png
        case "webp": return .webp
        case "heic", "heif": return .heic
        case "avif": return .avif
        default: return nil
        }
    }
}

// MARK: - Options & result

struct ProcessOptions {
    var format: OutputFormat = .webp
    var quality: Double = 80        // 0...100
    var lossless: Bool = false
    var maxDimension: Int? = nil    // longest side in px; nil = keep original size
}

struct ProcessResult {
    var data: Data
    var pixelWidth: Int
    var pixelHeight: Int
    var format: OutputFormat        // resolved (never .original)
    var fileExtension: String { format.fileExtension }
}

enum ImageError: LocalizedError {
    case cannotRead
    case cannotDecode
    case unsupportedOutput(String)
    case encodeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotRead: return "Impossible de lire le fichier."
        case .cannotDecode: return "Impossible de décoder l'image."
        case .unsupportedOutput(let f): return "Format de sortie non pris en charge : \(f)."
        case .encodeFailed(let why): return "Échec de l'encodage (\(why))."
        }
    }
}

// MARK: - Processor

enum ImageProcessor {

    /// Extensions we accept as input.
    static let supportedInputExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "webp", "heic", "heif",
        "avif", "tif", "tiff", "gif", "bmp"
    ]

    static func isSupported(url: URL) -> Bool {
        supportedInputExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: Load

    /// Decode an image, applying EXIF orientation and an optional downscale
    /// (never upscales). Returns a bitmap CGImage in device RGB.
    static func loadCGImage(url: URL, maxDimension: Int?) throws -> CGImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageError.cannotRead
        }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let pw = (props?[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let ph = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let haveDimensions = pw > 0 && ph > 0
        let longSide = max(pw, ph)

        // Cap the thumbnail at the original longest side so we never upscale.
        // The thumbnail API never enlarges past the source, so when the source
        // dimensions are unknown we use a very large ceiling rather than
        // accidentally collapsing to 1px.
        let noResizeCeiling = 1_000_000
        let target: Int
        if let m = maxDimension {
            target = haveDimensions ? min(m, longSide) : m
        } else {
            target = haveDimensions ? longSide : noResizeCeiling
        }

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
            kCGImageSourceCreateThumbnailWithTransform: true, // bake in EXIF orientation
        ]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw ImageError.cannotDecode
        }
        return img
    }

    // MARK: Process

    static func process(url: URL, options: ProcessOptions) throws -> ProcessResult {
        let img = try loadCGImage(url: url, maxDimension: options.maxDimension)

        let resolved: OutputFormat
        if options.format == .original {
            // Unknown/unsupported input containers (tiff/gif/bmp) fall back to
            // JPEG; overwrite-in-place is gated separately so this is safe.
            resolved = OutputFormat.from(extension: url.pathExtension) ?? .jpeg
        } else {
            resolved = options.format
        }

        let data: Data
        switch resolved {
        case .webp:
            data = try encodeWebP(img, quality: options.quality, lossless: options.lossless)
        case .jpeg:
            data = try encodeMozJPEG(img, quality: options.quality)
        case .png:
            data = try encodeImageIO(img, utType: UTType.png, quality: 1.0)
        case .heic:
            data = try encodeImageIO(img, utType: UTType.heic, quality: options.quality)
        case .avif:
            let avif = UTType("public.avif") ?? UTType.heic
            data = try encodeImageIO(img, utType: avif, quality: options.quality)
        case .original:
            throw ImageError.unsupportedOutput("original")
        }

        return ProcessResult(
            data: data,
            pixelWidth: img.width,
            pixelHeight: img.height,
            format: resolved
        )
    }

    // MARK: ImageIO encoders (JPEG / PNG / HEIC / AVIF)

    private static func encodeImageIO(_ img: CGImage, utType: UTType, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out as CFMutableData, utType.identifier as CFString, 1, nil
        ) else {
            throw ImageError.unsupportedOutput(utType.identifier)
        }
        let q = max(0.0, min(1.0, quality > 1 ? quality / 100.0 : quality))
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: q
        ]
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageError.encodeFailed(utType.identifier)
        }
        return out as Data
    }

    // MARK: Raw pixel access

    /// Draw a decoded image into a premultiplied-RGBA byte buffer (device RGB).
    /// When `matteWhite` is true the image is composited over an opaque white
    /// background first — used for formats without alpha (e.g. JPEG).
    private static func renderRGBA(_ img: CGImage, matteWhite: Bool) throws -> (buffer: [UInt8], bytesPerRow: Int) {
        let width = img.width
        let height = img.height
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue

        let drew: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: bitmapInfo
            ) else { return false }
            if matteWhite {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
                ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { throw ImageError.encodeFailed("bitmap") }
        return (buffer, bytesPerRow)
    }

    // MARK: JPEG encoder (mozjpeg)

    private static func encodeMozJPEG(_ img: CGImage, quality: Double) throws -> Data {
        // Composite over white (JPEG has no alpha); mozjpeg reads RGBA rows
        // directly, so no separate RGB buffer/pack step is needed.
        let (rgba, bytesPerRow) = try renderRGBA(img, matteWhite: true)

        let q = Int32(max(1, min(100, Int(quality.rounded()))))
        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outSize: Int = 0
        let ok = rgba.withUnsafeBufferPointer { bp -> Int32 in
            mozjpegshim_encode_rgba(
                bp.baseAddress,
                Int32(img.width),
                Int32(img.height),
                Int32(bytesPerRow),
                q,
                1, // progressive
                &outPtr,
                &outSize
            )
        }
        guard ok == 1, let outPtr, outSize > 0 else {
            throw ImageError.encodeFailed("mozjpeg")
        }
        let data = Data(bytes: outPtr, count: outSize)
        mozjpegshim_free(outPtr)
        return data
    }

    // MARK: WebP encoder (libwebp)

    private static func encodeWebP(_ img: CGImage, quality: Double, lossless: Bool) throws -> Data {
        var (buffer, bytesPerRow) = try renderRGBA(img, matteWhite: false)
        let width = img.width
        let height = img.height

        // CGContext produces premultiplied alpha; libwebp expects straight alpha.
        buffer.withUnsafeMutableBytes { raw in
            var vb = vImage_Buffer(
                data: raw.baseAddress,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: bytesPerRow
            )
            _ = vImageUnpremultiplyData_RGBA8888(&vb, &vb, vImage_Flags(kvImageNoFlags))
        }

        var outPtr: UnsafeMutablePointer<UInt8>? = nil
        var outSize: Int = 0
        let ok = buffer.withUnsafeBufferPointer { bp -> Int32 in
            webpshim_encode_rgba(
                bp.baseAddress,
                Int32(width),
                Int32(height),
                Int32(bytesPerRow),
                Float(quality),
                lossless ? 1 : 0,
                -1,
                &outPtr,
                &outSize
            )
        }
        guard ok == 1, let outPtr, outSize > 0 else {
            throw ImageError.encodeFailed("webp")
        }
        let data = Data(bytes: outPtr, count: outSize)
        webpshim_free(outPtr)
        return data
    }
}
