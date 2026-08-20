// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SpacetiMapboxBridge",
    platforms: [
        .iOS(.v14),
    ],
    products: [
        .library(name: "SpacetiMapboxBridge", targets: ["SpacetiMapboxBridge"]),
    ],
    dependencies: [
        .package(url: "https://github.com/mapbox/mapbox-maps-ios.git", exact: "11.28.0"),
    ],
    targets: [
        .target(
            name: "SpacetiMapboxBridge",
            dependencies: [
                .product(name: "MapboxMaps", package: "mapbox-maps-ios"),
            ],
            path: "Sources/SpacetiMapboxBridge"
        ),
    ]
)
