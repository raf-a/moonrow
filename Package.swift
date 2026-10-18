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
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .executable(name: "Moonrow", targets: ["Moonrow"]),
        .executable(name: "moonrow-ssh-helper", targets: ["moonrow-ssh-helper"]),
        .executable(name: "moonrow-mcp", targets: ["moonrow-mcp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.37.5"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.10.0"),
    ],
    targets: [
        .target(name: "SQLScript"),
        .target(name: "DBKit", dependencies: ["SQLScript"]),
        // SQLite with SQLCipher's encryption, built from its amalgamation in place of the system's
        // libsqlite3 (which can't open encrypted databases). See Sources/CSQLCipher/README.md.
        .target(
            name: "CSQLCipher",
            exclude: ["README.md", "LICENSE.md"],
            cSettings: [
                .define("SQLITE_HAS_CODEC"),
                .define("SQLCIPHER_CRYPTO_CC"),
                .define("SQLITE_TEMP_STORE", to: "2"),
                .define("SQLITE_EXTRA_INIT", to: "sqlcipher_extra_init"),
                .define("SQLITE_EXTRA_SHUTDOWN", to: "sqlcipher_extra_shutdown"),
                .define("SQLITE_THREADSAFE", to: "1"),
                .define("SQLITE_ENABLE_FTS4"),
                .define("SQLITE_ENABLE_FTS5"),
                .define("SQLITE_ENABLE_RTREE"),
                .define("SQLITE_ENABLE_GEOPOLY"),
                .define("SQLITE_ENABLE_MATH_FUNCTIONS"),
                .define("SQLITE_ENABLE_DBSTAT_VTAB"),
                .define("SQLITE_ENABLE_STAT4"),
                .define("SQLITE_ENABLE_COLUMN_METADATA"),
                .define("SQLITE_ENABLE_SNAPSHOT"),
                .define("HAVE_USLEEP", to: "1"),
                .define("NDEBUG"),
                // Optimized in debug builds too, so the grid stays as fast as with the system's
                // library; and the amalgamation's warnings aren't ours to fix.
                .unsafeFlags(["-O2", "-w"]),
            ],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "DriverSQLite", dependencies: ["DBKit", "SQLScript", "CSQLCipher"]),
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
        // SQLite files on a server, through the server's own sqlite3 over SSH.
        .target(
            name: "DriverRemoteSQLite",
            dependencies: ["DBKit", "SQLScript", "DriverSQLite", "WireSupport", .product(name: "NIOCore", package: "swift-nio")]
        ),
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
        .target(name: "AppCore", dependencies: ["SQLScript", "DBKit", "WireSupport", "SSHTunnel", "DriverSQLite", "DriverPostgres", "DriverMySQL", "DriverRemoteSQLite"]),
        // The MCP server: Streamable HTTP on SwiftNIO, the tools over the app's connections.
        .target(
            name: "MCPServer",
            dependencies: [
                "AppCore", "DBKit", "SQLScript", "WireSupport", "DriverSQLite",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        // The stdio bridge MCP clients run; forwards to the app's server. Bundled next to the
        // app's executable.
        .executableTarget(name: "moonrow-mcp"),
        // The AppKit app. `scripts/build-app.sh` wraps it into Moonrow.app.
        .executableTarget(
            name: "Moonrow",
            dependencies: ["AppCore", "MCPServer", .product(name: "Sparkle", package: "Sparkle")],
            // SwiftPM links with `-platform_version macos 14.0 14.0`, which stamps the binary as
            // built against SDK 14, and AppKit then keeps the pre-macOS 26 look. Linking as built
            // against SDK 26 turns on Liquid Glass; macOS 14 is still the minimum.
            // `scripts/build-app.sh` copies Sparkle.framework into Contents/Frameworks.
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-platform_version", "-Xlinker", "macos", "-Xlinker", "14.0", "-Xlinker", "26.0",
                "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
            ])]
        ),
        .testTarget(name: "SQLScriptTests", dependencies: ["SQLScript"]),
        .testTarget(name: "DBKitTests", dependencies: ["DBKit"]),
        .testTarget(name: "DriverSQLiteTests", dependencies: ["DriverSQLite"]),
        .testTarget(name: "DriverPostgresTests", dependencies: ["DriverPostgres", "WireSupport"]),
        .testTarget(name: "DriverMySQLTests", dependencies: ["DriverMySQL", "WireSupport"]),
        // The TLS upgrade against a scripted server on loopback, through WireChannel and both drivers.
        .testTarget(
            name: "WireSupportTests",
            dependencies: [
                "WireSupport", "DBKit", "DriverMySQL", "DriverPostgres",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .testTarget(name: "AppCoreTests", dependencies: ["AppCore", "WireSupport", "DriverSQLite", "DriverPostgres", "DriverMySQL", "DriverRemoteSQLite"]),
        // Depends on the bridge so `swift test` builds it next to the test bundle.
        .testTarget(name: "MCPServerTests", dependencies: ["MCPServer", "AppCore", "DBKit", "DriverSQLite", "DriverPostgres", "DriverMySQL", "moonrow-mcp"]),
        // Depends on the helper so `swift test` builds it next to the test bundle.
        .testTarget(
            name: "SSHTunnelTests",
            dependencies: ["SSHTunnel", "AppCore", "WireSupport", "DriverPostgres", "DriverMySQL", "DriverSQLite", "DriverRemoteSQLite", "moonrow-ssh-helper"],
            exclude: ["Fixtures"]
        ),
    ]
)
