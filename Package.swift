// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Moonrow",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SQLScript", targets: ["SQLScript"]),
        .library(name: "DBKit", targets: ["DBKit"]),
        .library(name: "DriverSQLite", targets: ["DriverSQLite"]),
        .library(name: "DriverPostgres", targets: ["DriverPostgres"]),
        .library(name: "DriverMySQL", targets: ["DriverMySQL"]),
        .library(name: "SSHTunnel", targets: ["SSHTunnel"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .executable(name: "Moonrow", targets: ["Moonrow"]),
        .executable(name: "moonrow-ssh-helper", targets: ["moonrow-ssh-helper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
    ],
    targets: [
        .target(name: "SQLScript"),
        .target(name: "DBKit", dependencies: ["SQLScript"]),
        .target(
            name: "DriverSQLite",
            dependencies: ["DBKit", "SQLScript"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // Socket, TLS upgrade and framing shared by the network drivers.
        .target(
            name: "WireSupport",
            dependencies: [
                "DBKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(name: "DriverPostgres", dependencies: ["DBKit", "WireSupport"]),
        .target(name: "DriverMySQL", dependencies: ["DBKit", "WireSupport"]),
        // Database sockets carried over the system's OpenSSH client.
        .target(
            name: "SSHTunnel",
            dependencies: [
                "DBKit", "WireSupport",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
        // SSH_ASKPASS helper ssh runs to ask for passwords; relays prompts to the app. Bundled
        // next to the app's executable.
        .executableTarget(name: "moonrow-ssh-helper"),
        // App logic without AppKit, so `swift test` covers it.
        .target(name: "AppCore", dependencies: ["SQLScript", "DBKit", "WireSupport", "SSHTunnel", "DriverSQLite", "DriverPostgres", "DriverMySQL"]),
        // The AppKit app. `scripts/build-app.sh` wraps it into Moonrow.app.
        .executableTarget(
            name: "Moonrow",
            dependencies: ["AppCore"],
            // SwiftPM links with `-platform_version macos 14.0 14.0`, which stamps the binary as
            // built against SDK 14, and AppKit then keeps the pre-macOS 26 look. Linking as built
            // against SDK 26 turns on Liquid Glass; macOS 14 is still the minimum.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0"])]
        ),
        .testTarget(name: "SQLScriptTests", dependencies: ["SQLScript"]),
        .testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
        .testTarget(name: "DriverSQLiteTests", dependencies: ["DriverSQLite"]),
        .testTarget(name: "DriverPostgresTests", dependencies: ["DriverPostgres", "WireSupport"]),
        .testTarget(name: "DriverMySQLTests", dependencies: ["DriverMySQL", "WireSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "WireSupport", "DriverSQLite", "DriverPostgres", "DriverMySQL"]),
        // Depends on the helper so `swift test` builds it next to the test bundle.
        .testTarget(
            name: "SSHTunnelTests",
            dependencies: ["SSHTunnel", "AppCore", "WireSupport", "DriverPostgres", "DriverMySQL", "moonrow-ssh-helper"],
            exclude: ["Fixtures"]
        ),
    ]
)
