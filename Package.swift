// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ResourceVisualizer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ResourceVisualizer", targets: ["ResourceVisualizer"])],
    targets: [
        // The same C++ backend the terminal tool uses, exposed through monitor_c.h.
        .target(
            name: "MonitorBackend",
            path: "src/monitor",
            sources: ["macos.cpp", "bridge.cpp"],
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation")]
        ),
        .executableTarget(
            name: "ResourceVisualizer",
            dependencies: ["MonitorBackend"],
            path: "app/ResourceVisualizer"
        ),
    ],
    cxxLanguageStandard: .cxx17
)
