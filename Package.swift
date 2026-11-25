// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "EQLisa",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(
            name: "EQLisa",
            path: "Sources/EQLisa",
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
            ]
        )
    ]
)
