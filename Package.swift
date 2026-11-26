// swift-tools-version: 6.0
import Foundation
import PackageDescription

let isWasmBuild = ProcessInfo.processInfo.environment["SWIFTWASM_BUILD"] == "1"

let packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/swiftwasm/JavaScriptKit.git", from: "0.22.0")
]
var packageProducts: [Product] = [
    .library(
        name: "Engine",
        targets: ["Engine"]
    )
]
var packageTargets: [Target] = [
    .target(
        name: "Engine",
        path: "Sources/Engine"
    ),
    .testTarget(
        name: "EngineTests",
        dependencies: ["Engine"],
        path: "Tests/EngineTests"
    )
]

if isWasmBuild {
    packageProducts.append(
        .executable(name: "MunchiesApp", targets: ["App"])
    )
    packageTargets.append(
        .executableTarget(
            name: "App",
            dependencies: [
                "Engine",
                .product(name: "JavaScriptKit", package: "JavaScriptKit"),
                .product(name: "JavaScriptEventLoop", package: "JavaScriptKit")
            ],
            path: "Sources/App",
            linkerSettings: [.unsafeFlags(["-Xlinker", "--strip-debug"], .when(platforms: [.wasi]))]
        )
    )
}

let package = Package(
    name: "Munchies",
    platforms: [
        .macOS(.v15)
    ],
    products: packageProducts,
    dependencies: packageDependencies,
    targets: packageTargets
)
