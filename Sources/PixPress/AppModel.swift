import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Item

enum ItemStatus: Equatable {
    case pending
    case processing
    case done
    case failed(String)
}

struct ImageItem: Identifiable {
    let id = UUID()
    let url: URL
    var originalSize: Int
    var thumbnail: NSImage?
    var status: ItemStatus = .pending

    // Result of the last compression (kept in memory until saved).
    var resultData: Data?
    var newSize: Int?
    var outputFormat: OutputFormat?   // the format actually encoded (drives extension + safe overwrite)
    var pixelWidth: Int?
    var pixelHeight: Int?
    var savedURL: URL?

    var savingsRatio: Double? {
        guard let newSize, originalSize > 0 else { return nil }
        return 1.0 - (Double(newSize) / Double(originalSize))
    }
}

// MARK: - Output destination

enum OutputMode: String, CaseIterable, Identifiable {
    case besideOriginal
    case overwriteOriginal
    case chooseFolder

    var id: String { rawValue }
    var label: String {
        switch self {
        case .besideOriginal: return "À côté des originaux"
        case .overwriteOriginal: return "Écraser les originaux"
        case .chooseFolder: return "Dossier de sortie…"
        }
    }
}

// MARK: - Model

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [ImageItem] = []

    // Settings
    @Published var format: OutputFormat = .webp { didSet { settingsChanged() } }
    @Published var quality: Double = 80 { didSet { settingsChanged() } }
    @Published var lossless: Bool = false { didSet { settingsChanged() } }
    @Published var resizeEnabled: Bool = false { didSet { settingsChanged() } }
    @Published var maxDimension: Double = 2048 { didSet { settingsChanged() } }
    @Published var outputMode: OutputMode = .besideOriginal
    @Published var outputFolder: URL? = nil

    @Published var isBusy: Bool = false

    // Coalesces rapid setting changes into a single recompress.
    private var debounceTask: Task<Void, Never>?
    // Identifies the current settings cycle so stale results can be discarded.
    private var currentGeneration = 0

    /// Smallest longest-side, in px, allowed when resizing — guards against a
    /// cleared/zero field collapsing every image to a tiny size.
    static let minResizeDimension = 16

    var currentOptions: ProcessOptions {
        let clamped = max(Self.minResizeDimension, Int(maxDimension))
        return ProcessOptions(
            format: format,
            quality: quality,
            lossless: lossless,
            maxDimension: resizeEnabled ? clamped : nil
        )
    }

    /// The re-encodable output format of an item's input, or nil for inputs
    /// with no exact output (tiff/gif/bmp).
    private func inputFormat(of item: ImageItem) -> OutputFormat? {
        OutputFormat.from(extension: item.url.pathExtension)
    }

    /// True when this item's output *would* be the same format as its input
    /// under the current settings (drives whether the overwrite option is shown).
    func sameFormatAsInput(_ item: ImageItem) -> Bool {
        guard let input = inputFormat(of: item) else { return false }
        let resolved = (format == .original) ? input : format
        return resolved == input
    }

    /// True only when the *already-encoded* result matches the original's
    /// format — the safe condition for overwriting in place. Uses the stored
    /// result (not the live setting), so an in-flight recompress can't cause a
    /// mismatched-format overwrite.
    func resultMatchesOriginalFormat(_ item: ImageItem) -> Bool {
        guard let encoded = item.outputFormat, let input = inputFormat(of: item) else { return false }
        return encoded == input
    }

    /// Overwriting is only offered when at least one loaded item keeps its format.
    var canOverwrite: Bool {
        !items.isEmpty && items.contains { sameFormatAsInput($0) }
    }

    /// Destination modes to show, given the current format/items.
    var availableOutputModes: [OutputMode] {
        var modes: [OutputMode] = [.besideOriginal]
        if canOverwrite { modes.append(.overwriteOriginal) }
        modes.append(.chooseFolder)
        return modes
    }

    /// Fall back to a safe mode if "overwrite" is selected but no longer applicable.
    private func normalizeOutputMode() {
        if outputMode == .overwriteOriginal && !canOverwrite {
            outputMode = .besideOriginal
        }
    }

    // Aggregate stats over items that have a compression result, in one pass.
    struct SaveStats {
        var original = 0
        var new = 0
        var savings: Double? {
            (original > 0 && new > 0) ? 1.0 - Double(new) / Double(original) : nil
        }
    }
    var stats: SaveStats {
        var s = SaveStats()
        for item in items {
            guard let newSize = item.newSize else { continue }
            s.original += item.originalSize
            s.new += newSize
        }
        return s
    }

    // MARK: Adding files

    func addURLs(_ urls: [URL]) {
        let expanded = expand(urls)
        var seen = Set(items.map { $0.url })
        var added: [UUID] = []
        for url in expanded {
            guard ImageProcessor.isSupported(url: url) else { continue }
            guard seen.insert(url).inserted else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let item = ImageItem(url: url, originalSize: size)
            items.append(item)
            added.append(item.id)
        }
        for id in added {
            loadThumbnail(id: id)
            Task { await process(id: id) }
        }
        normalizeOutputMode()
    }

    /// Expand any directories into their image files, recursing into
    /// subfolders but skipping hidden files and the contents of file packages
    /// (e.g. .app, .photoslibrary) so a dropped folder can't pull in a whole
    /// bundle.
    private func expand(_ urls: [URL]) -> [URL] {
        var result: [URL] = []
        let fm = FileManager.default
        for url in urls {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                if let en = fm.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) {
                    for case let f as URL in en where ImageProcessor.isSupported(url: f) {
                        result.append(f)
                    }
                }
            } else {
                result.append(url)
            }
        }
        return result
    }

    func clear() {
        items.removeAll()
        normalizeOutputMode()
    }

    func removeItem(id: UUID) {
        items.removeAll { $0.id == id }
        normalizeOutputMode()
    }

    // MARK: Thumbnails

    private func loadThumbnail(id: UUID) {
        guard let url = items.first(where: { $0.id == id })?.url else { return }
        Task.detached(priority: .utility) {
            let thumb = Self.makeThumbnail(url: url, maxPixel: 96)
            await MainActor.run {
                if let idx = self.items.firstIndex(where: { $0.id == id }) {
                    self.items[idx].thumbnail = thumb
                }
            }
        }
    }

    nonisolated static func makeThumbnail(url: URL, maxPixel: Int) -> NSImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    // MARK: Processing

    /// Any setting change schedules a debounced recompress so the estimates
    /// always reflect the current settings.
    private func settingsChanged() {
        normalizeOutputMode()
        guard !items.isEmpty else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            self?.recompressAll()
        }
    }

    /// Re-run compression for every item with the current settings.
    func recompressAll() {
        currentGeneration += 1
        let gen = currentGeneration
        for item in items {
            Task { await process(id: item.id, generation: gen) }
        }
    }

    func process(id: UUID, generation: Int? = nil) async {
        guard let idx0 = items.firstIndex(where: { $0.id == id }) else { return }
        let gen = generation ?? currentGeneration
        let url = items[idx0].url
        let options = currentOptions
        items[idx0].status = .processing
        isBusy = true

        let outcome: Result<ProcessResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                return .success(try ImageProcessor.process(url: url, options: options))
            } catch {
                return .failure(error)
            }
        }.value

        // Discard results superseded by a newer settings change.
        guard gen == currentGeneration else {
            isBusy = items.contains { $0.status == .processing }
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .success(let r):
            items[idx].resultData = r.data
            items[idx].newSize = r.data.count
            items[idx].outputFormat = r.format
            items[idx].pixelWidth = r.pixelWidth
            items[idx].pixelHeight = r.pixelHeight
            items[idx].savedURL = nil
            items[idx].status = .done
        case .failure(let e):
            items[idx].status = .failed(e.localizedDescription)
            items[idx].resultData = nil
            items[idx].newSize = nil
            items[idx].outputFormat = nil
        }
        isBusy = items.contains { $0.status == .processing }
    }

    // MARK: Saving

    /// Save every processed item. Returns the number written.
    @discardableResult
    func saveAll() -> Int {
        // Confirm before overwriting originals — destructive and irreversible.
        if outputMode == .overwriteOriginal {
            let toOverwrite = items.filter { $0.resultData != nil && resultMatchesOriginalFormat($0) }.count
            if toOverwrite > 0 && !confirmOverwrite(count: toOverwrite) { return 0 }
        }

        var destinationFolder: URL? = outputFolder
        if outputMode == .chooseFolder && destinationFolder == nil {
            destinationFolder = promptForFolder()
            if destinationFolder == nil { return 0 }
            outputFolder = destinationFolder
        }

        var count = 0
        for idx in items.indices {
            guard let data = items[idx].resultData,
                  let ext = items[idx].outputFormat?.fileExtension else { continue }
            let original = items[idx].url
            let baseName = original.deletingPathExtension().lastPathComponent

            let dest: URL
            if outputMode == .overwriteOriginal && resultMatchesOriginalFormat(items[idx]) {
                // Replace the original file in place, keeping its own name/extension.
                dest = original
            } else {
                // "Beside", a format conversion, or a chosen folder — never destroy
                // an original: write a unique, non-clobbering path.
                let directory = (outputMode == .chooseFolder ? destinationFolder : nil)
                    ?? original.deletingLastPathComponent()
                dest = uniqueDestination(
                    directory: directory, baseName: baseName, ext: ext, originalURL: original)
            }

            do {
                try data.write(to: dest, options: .atomic)
                items[idx].savedURL = dest
                count += 1
            } catch {
                items[idx].status = .failed("Écriture impossible : \(error.localizedDescription)")
            }
        }
        return count
    }

    private func confirmOverwrite(count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1
            ? "Écraser 1 fichier original ?"
            : "Écraser \(count) fichiers originaux ?"
        alert.informativeText = "Les fichiers d'origine seront remplacés par leur version compressée. Cette action est irréversible."
        alert.addButton(withTitle: "Écraser")
        alert.addButton(withTitle: "Annuler")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Build a destination path that never overwrites the source or an existing file.
    private func uniqueDestination(directory: URL, baseName: String, ext: String, originalURL: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(baseName).appendingPathExtension(ext)
        // Avoid clobbering the original file (same format, same folder).
        if candidate.standardizedFileURL == originalURL.standardizedFileURL {
            candidate = directory.appendingPathComponent("\(baseName)-min").appendingPathExtension(ext)
        }
        var n = 1
        while fm.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(n)").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }

    /// Prompt for and store the output folder.
    func chooseOutputFolder() {
        if let url = promptForFolder() { outputFolder = url }
    }

    private func promptForFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choisir"
        panel.message = "Dossier de destination des images compressées"
        return panel.runModal() == .OK ? panel.url : nil
    }

    // MARK: File picker

    func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Ajouter"
        if panel.runModal() == .OK {
            addURLs(panel.urls)
        }
    }
}

// MARK: - Formatting helpers

func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}
