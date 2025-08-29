// Package.swift
// swift-tools-version: 6.1

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "Resolvable",
    // Require OSes that support SwiftData/Observation so we can use @Model/@Observable directly.
    platforms: [.macOS(.v14), .iOS(.v17), .tvOS(.v17), .watchOS(.v10), .macCatalyst(.v17)],
    products: [
        .library(name: "Resolvable", targets: ["Resolvable"]),
        .executable(name: "ResolvableClient", targets: ["ResolvableClient"]),
        // New Storable product + client
        .library(name: "Storable", targets: ["Storable"]),
        .executable(name: "StorableClient", targets: ["StorableClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0-latest"),
    ],
    targets: [
        // Existing Resolvable macro plugin
        .macro(
            name: "ResolvableMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        // Existing Resolvable library and client
        .target(name: "Resolvable", dependencies: ["ResolvableMacros"]),
        .executableTarget(name: "ResolvableClient", dependencies: ["Resolvable"]),

        // New Storable macro plugin
        .macro(
            name: "StorableMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax")
            ]
        ),
        // New Storable library surface
        .target(name: "Storable", dependencies: ["StorableMacros"]),
        // New Storable demo client
        .executableTarget(name: "StorableClient", dependencies: ["Storable"]),
    ]
)
