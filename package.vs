// The 'archive' repository: standard archive formats (tar, zip) for Vertex.
import PackageDescription

let package = Package(
    name: "archive",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(name: "archive/tar", targets: ["tar"]),
        .library(name: "archive/zip", targets: ["zip"]),
        .executable(name: "check", targets: ["check"]),
    ],
    targets: [
        // tar: POSIX.1-1988 USTAR streaming archive reader and writer.
        .target(
            name: "tar",
            path: "tar"
        ),
        // zip: PKWARE / RFC 1951 DEFLATE archive reader and writer.
        .target(
            name: "zip",
            path: "zip"
        ),
        // Test suite.
        .executableTarget(
            name: "check",
            dependencies: ["tar", "zip"],
            path: "tests/check"
        ),
    ]
)
