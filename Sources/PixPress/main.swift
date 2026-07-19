import SwiftUI
import AppKit
import Foundation

// Entry point. A hidden `--cli` mode lets us exercise the compression engine
// headlessly (useful for testing); otherwise we launch the SwiftUI app.

if CommandLine.arguments.contains("--cli") {
    CLI.run(CommandLine.arguments)
} else {
    PixPressApp.main()
}

// MARK: - SwiftUI app

struct PixPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        // A single, unique window (not WindowGroup) so opening several files at
        // once funnels them all into one window instead of spawning one per file.
        Window("PixPress", id: "main") {
            ContentView()
                .environmentObject(model)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ajouter des images…") { model.openFilePicker() }
                    .keyboardShortcut("o")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Files opened via Finder's "Open With…", double-click, or dropped on the
    /// Dock icon arrive here. Route them into the shared model.
    func application(_ application: NSApplication, open urls: [URL]) {
        AppModel.shared.addURLs(urls)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - CLI

enum CLI {
    static func run(_ args: [String]) {
        // Usage: PixPress --cli <input> <output> [--format webp|jpeg|png|heic|avif]
        //                 [--quality N] [--lossless] [--max N]
        var positional: [String] = []
        var format = OutputFormat.webp
        var quality = 80.0
        var lossless = false
        var maxDim: Int? = nil

        var i = 1
        while i < args.count {
            let a = args[i]
            switch a {
            case "--cli": break
            case "--format":
                i += 1
                if i < args.count, let f = OutputFormat(rawValue: args[i]) { format = f }
            case "--quality":
                i += 1
                if i < args.count, let q = Double(args[i]) { quality = q }
            case "--lossless":
                lossless = true
            case "--max":
                i += 1
                if i < args.count, let m = Int(args[i]) { maxDim = m }
            default:
                positional.append(a)
            }
            i += 1
        }

        guard positional.count >= 2 else {
            FileHandle.standardError.write(Data("Usage: PixPress --cli <input> <output> [--format ...] [--quality N] [--lossless] [--max N]\n".utf8))
            exit(2)
        }
        let input = URL(fileURLWithPath: positional[0])
        let output = URL(fileURLWithPath: positional[1])
        let options = ProcessOptions(format: format, quality: quality, lossless: lossless, maxDimension: maxDim)

        do {
            let originalSize = (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let result = try ImageProcessor.process(url: input, options: options)
            try result.data.write(to: output)
            let pct = originalSize > 0 ? (1 - Double(result.data.count) / Double(originalSize)) * 100 : 0
            print(String(format: "OK  %@  %d×%d  %d → %d octets  (−%.1f%%)",
                         result.format.label, result.pixelWidth, result.pixelHeight,
                         originalSize, result.data.count, pct))
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("ERREUR: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }
}
