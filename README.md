# kmp-swift-mapbox-bridge

Swift package bridging the [Mapbox Maps iOS SDK](https://github.com/mapbox/mapbox-maps-ios)
to Kotlin Multiplatform via an `@objc` interface.

## Why this exists

The Mapbox Maps SDK for iOS (v11+) is a pure-Swift library with no Objective-C API, so
Kotlin/Native cannot call it directly. This package provides a thin `@objc` shim
(`SPMapboxBridge`) that exposes the map operations the shared code needs — camera control,
GeoJSON sources and layers, floor-plan images, feature queries, kiosk-mode attribution — as
plain Objective-C methods that Kotlin/Native can message.

It contains **only Swift code**; there is no Kotlin here. The `kmp-` in the name refers to the
consumer (a Kotlin Multiplatform project), not the contents.

## How it is consumed

`spaceti-shared` depends on this package as a **versioned remote SwiftPM dependency**. Publishing
the bridge to its own repository (rather than a local path) keeps `spaceti-shared`'s published
artifact self-contained: the SwiftPM linkage carries a resolvable URL instead of a build-machine
path, so downstream Gradle consumers (e.g. the meeting-room app) can build iOS straight from the
published artifact.

```swift
.package(url: "https://github.com/spaceti/kmp-swift-mapbox-bridge.git", exact: "1.0.0")
```

## Mapbox version

The Mapbox dependency is pinned to `exact("11.28.0")` and must stay aligned with every consumer
(the Kotlin framework build and each host app). Two `.exact` requirements on Mapbox can only
co-resolve when they are the same version, so bump this pin only together with the consumers.

## Versioning

Releases are plain semver git tags (`1.0.0`, `1.1.0`, …). Bump the tag whenever the bridge
sources change, then point the consumer at the new tag. The bridge changes rarely, so this is
infrequent.
