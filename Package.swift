// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SQLScript", targets: ["SQLScript"]),
        .library(name: "DBKit", targets: ["DBKit"]),
        .library(name: "DriverSQLite", targets: ["DriverSQLite"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .executable(name: "Tabula", targets: ["Tabula"]),
    ],
    targets: [
        .target(name: "SQLScript"),
        .target(name: "DBKit", dependencies: ["SQLScript"]),
        .target(
            name: "DriverSQLite",
            dependencies: ["DBKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // App logic without AppKit, so `swift test` covers it.
        .target(name: "AppCore", dependencies: ["SQLScript", "DBKit", "DriverSQLite"]),
        // The AppKit app. `scripts/build-app.sh` wraps it into Tabula.app.
        .executableTarget(name: "Tabula", dependencies: ["AppCore"]),
        .testTarget(name: "SQLScriptTests", dependencies: ["SQLScript"]),
        .testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
        .testTarget(name: "DriverSQLiteTests", dependencies: ["DriverSQLite"]),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "DriverSQLite"]),
    ]
)
