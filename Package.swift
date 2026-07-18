// swift-tools-version: 6.0
import PackageDescription

// Homebrew prefix where libwebp (headers + static archives) lives.
let brew = "/opt/homebrew"
// mozjpeg is keg-only, so it lives under its own opt prefix.
let mozjpeg = "/opt/homebrew/opt/mozjpeg"

let package = Package(
    name: "PixPress",
    platforms: [.macOS(.v15)],
    targets: [
        // Thin C wrapper around libwebp's encoder.
        .target(
            name: "CWebPShim",
            cSettings: [
                .unsafeFlags(["-I\(brew)/include"])
            ]
        ),
        // Thin C wrapper around mozjpeg's encoder.
        .target(
            name: "CMozJPEGShim",
            cSettings: [
                .unsafeFlags(["-I\(mozjpeg)/include"])
            ]
        ),
        // The SwiftUI application.
        .executableTarget(
            name: "PixPress",
            dependencies: ["CWebPShim", "CMozJPEGShim"],
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            linkerSettings: [
                // Statically link libwebp + libsharpyuv + mozjpeg so the .app
                // does not depend on Homebrew at runtime.
                .unsafeFlags([
                    "\(brew)/lib/libwebp.a",
                    "\(brew)/lib/libsharpyuv.a",
                    "\(mozjpeg)/lib/libjpeg.a",
                ])
            ]
        ),
    ]
)
