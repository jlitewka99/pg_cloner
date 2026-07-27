// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "PGCloner",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "PGClonerCore", targets: ["PGClonerCore"]),
        .library(name: "PGClonerPostgres", targets: ["PGClonerPostgres"]),
        .executable(name: "PGClonerApp", targets: ["PGClonerApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        // Newer NIO releases expose Span APIs shipped only by the macOS 26 SDK.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.83.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.30.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        // 1.6 requires the macOS 26 standard library's Span API. Pinning 1.1.4
        // keeps the package buildable with the macOS 14/15 SDKs supported by v1.
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.1.4"),
        // 1.1.x references macOS 26-only SendableMetatype APIs when compiled
        // by Swift 6.2+, even if the selected deployment SDK is older.
        .package(url: "https://github.com/apple/swift-async-algorithms.git", exact: "1.0.4"),
        // The local Command Line Tools contain Swift Testing for the macOS 26
        // standard library only. Build the Swift 6.1 release from source so
        // tests also run against the macOS 14/15 SDK used by this application.
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.1.3-RELEASE"
        )
    ],
    targets: [
        .target(
            name: "PGClonerCore",
            resources: [
                .copy("Resources/transformations.json")
            ]
        ),
        .target(
            name: "PGClonerPostgres",
            dependencies: [
                "PGClonerCore",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
                // Direct references keep the compatibility pins intentional
                // instead of relying on whatever transitive version is newest.
                .product(name: "DequeModule", package: "swift-collections"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms")
            ]
        ),
        .executableTarget(
            name: "PGClonerApp",
            dependencies: [
                "PGClonerCore",
                "PGClonerPostgres",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/PGClonerApp",
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .define("PGCLONER_APP")
            ],
            linkerSettings: [
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "PGClonerCoreTests",
            dependencies: [
                "PGClonerCore",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "PGClonerPostgresTests",
            dependencies: [
                "PGClonerCore",
                "PGClonerPostgres",
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "PGClonerIntegrationTests",
            dependencies: [
                "PGClonerCore",
                "PGClonerPostgres",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Testing", package: "swift-testing")
            ]
        ),
        .testTarget(
            name: "PGClonerAppTests",
            dependencies: [
                "PGClonerApp",
                .product(name: "Testing", package: "swift-testing")
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
