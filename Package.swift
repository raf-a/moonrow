// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SQLScript", targets: ["SQLScript"]),
        .library(name: "DBKit", targets: ["DBKit"]),
        .library(name: "DriverSQLite", targets: ["DriverSQLite"]),
        .library(name: "DriverPostgres", targets: ["DriverPostgres"]),
        .library(name: "DriverMySQL", targets: ["DriverMySQL"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .executable(name: "Tabula", targets: ["Tabula"]),
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
        // App logic without AppKit, so `swift test` covers it.
        .target(name: "AppCore", dependencies: ["SQLScript", "DBKit", "WireSupport", "DriverSQLite", "DriverPostgres", "DriverMySQL"]),
        // The AppKit app. `scripts/build-app.sh` wraps it into Tabula.app.
        .executableTarget(name: "Tabula", dependencies: ["AppCore"]),
        .testTarget(name: "SQLScriptTests", dependencies: ["SQLScript"]),
        .testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
        .testTarget(name: "DriverSQLiteTests", dependencies: ["DriverSQLite"]),
        .testTarget(name: "DriverPostgresTests", dependencies: ["DriverPostgres", "WireSupport"]),
        .testTarget(name: "DriverMySQLTests", dependencies: ["DriverMySQL", "WireSupport"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "WireSupport", "DriverSQLite", "DriverPostgres", "DriverMySQL"]),
    ]
)
