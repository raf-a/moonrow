// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SQLScript", targets: ["SQLScript"]),
        .library(name: "DBKit", targets: ["DBKit"]),
        .library(name: "DriverSQLite", targets: ["DriverSQLite"]),
    ],
    targets: [
        .target(name: "SQLScript"),
        .target(name: "DBKit", dependencies: ["SQLScript"]),
        .target(
            name: "DriverSQLite",
            dependencies: ["DBKit"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(name: "SQLScriptTests", dependencies: ["SQLScript"]),
        .testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
        .testTarget(name: "DriverSQLiteTests", dependencies: ["DriverSQLite"]),
    ]
)
