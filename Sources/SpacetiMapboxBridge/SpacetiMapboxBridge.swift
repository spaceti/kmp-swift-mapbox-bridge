import Foundation
import UIKit
import CoreGraphics
import CoreLocation
import MapboxMaps

@objc(SPMapboxBridge)
public final class SPMapboxBridge: NSObject {

    @objc public static func setAccessToken(_ token: String) {
        MapboxOptions.accessToken = token
    }

    @objc public var view: UIView { mapView }

    @objc public var onMapLoaded: (() -> Void)?
    @objc public var onCameraChanged: ((Double, Double, Double, Double, Double) -> Void)?
    @objc public var onMapClicked: ((Double, Double) -> Void)?
    @objc public var onFeatureClicked: ((String, String?, String?, Double, Double) -> Void)?
    /// Fired when the user pans the map by hand (drag gesture); used to drop "follow my location".
    @objc public var onMapPanned: (() -> Void)?

    private let mapView: MapView
    private var visibleLayerIds: [String] = []
    private var addedSourceIds: Set<String> = []
    private var addedLayerIds: Set<String> = []
    private var nextSourceIds: Set<String> = []
    private var nextLayerIds: Set<String> = []
    private var addedImageIds: Set<String> = []
    private var cameraObserver: AnyCancelable?
    private var tapObserver: AnyCancelable?
    private var locationObserver: AnyCancelable?
    private var lastUserLocation: CLLocationCoordinate2D?
    // One-shot "recenter as soon as a fix arrives" request, so the first tap still moves the camera
    // even before the puck has reported a position. `pendingRecenterZoom == nil` keeps the zoom.
    private var hasPendingRecenter = false
    private var pendingRecenterZoom: Double?
    private var suppressCameraEvents = false
    private var hasFitted = false

    @objc public override convenience init() {
        self.init(suppressExternalLinks: false)
    }

    /// - Parameter suppressExternalLinks: kiosk mode — the attribution menu stays functional
    ///   (including the telemetry consent alert), but its web links never open a browser.
    @objc public init(suppressExternalLinks: Bool) {
        if suppressExternalLinks {
            self.mapView = MapView(
                frame: .zero,
                mapInitOptions: MapInitOptions(),
                urlOpener: KioskAttributionURLOpener()
            )
        } else {
            self.mapView = MapView(frame: .zero)
        }
        super.init()
        configureGestures()
        installObservers()
        mapView.gestures.delegate = self
    }

    private func configureGestures() {
        // Flat-map gestures, matching the original: no pitch (tilt), everything else enabled.
        mapView.gestures.options.pitchEnabled = false
        // Hide the scale-bar ornament (visible in the default `.adaptive` mode), matching Android.
        mapView.ornaments.options.scaleBar.visibility = .hidden
    }

    // Locks/unlocks user input during a programmatic camera animation so the user can't pan away
    // before the target (e.g. the selected space) is in view. Pitch stays disabled (flat map).
    private func setGesturesEnabled(_ enabled: Bool) {
        mapView.gestures.options.panEnabled = enabled
        mapView.gestures.options.pinchEnabled = enabled
        mapView.gestures.options.rotateEnabled = enabled
        mapView.gestures.options.doubleTapToZoomInEnabled = enabled
        mapView.gestures.options.doubleTouchToZoomOutEnabled = enabled
        mapView.gestures.options.quickZoomEnabled = enabled
        mapView.gestures.options.pitchEnabled = false
    }

    @objc public func dispose() {
        cameraObserver = nil
        tapObserver = nil
        locationObserver = nil
        onMapLoaded = nil
        onCameraChanged = nil
        onMapClicked = nil
        onFeatureClicked = nil
        onMapPanned = nil
    }

    private func installObservers() {
        cameraObserver = mapView.mapboxMap.onCameraChanged.observe { [weak self] _ in
            guard let self = self, !self.suppressCameraEvents else { return }
            self.emitCameraChanged()
        }

        tapObserver = mapView.gestures.onMapTap.observe { [weak self] context in
            guard let self = self else { return }
            self.onMapClicked?(context.coordinate.latitude, context.coordinate.longitude)
            self.queryFeatures(at: context.point, coordinate: context.coordinate)
        }
    }

    private func emitCameraChanged() {
        let state = mapView.mapboxMap.cameraState
        onCameraChanged?(
            state.center.latitude,
            state.center.longitude,
            state.zoom,
            state.bearing,
            state.pitch
        )
    }

    @objc public func setCamera(
        latitude: Double,
        longitude: Double,
        zoom: Double,
        bearing: Double,
        pitch: Double
    ) {
        let options = CameraOptions(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            zoom: zoom,
            bearing: bearing,
            pitch: pitch
        )
        suppressCameraEvents = true
        mapView.mapboxMap.setCamera(to: options)
        suppressCameraEvents = false
        emitCameraChanged()
    }

    @objc public func flyTo(
        latitude: Double,
        longitude: Double,
        zoom: Double,
        bearing: Double,
        pitch: Double
    ) {
        let options = CameraOptions(
            center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            zoom: zoom,
            bearing: bearing,
            pitch: pitch
        )
        suppressCameraEvents = true
        setGesturesEnabled(false)
        mapView.camera.fly(to: options) { [weak self] _ in
            self?.suppressCameraEvents = false
            self?.setGesturesEnabled(true)
            self?.emitCameraChanged()
        }
    }

    /// Shows/hides the device-location "blue dot" puck. Mapbox reads the device location itself
    /// (given the app holds the location permission); we observe it to answer recenterOnUserLocation.
    @objc public func setShowsUserLocation(_ enabled: Bool) {
        if enabled {
            mapView.location.options.puckType = .puck2D()
            if locationObserver == nil {
                locationObserver = mapView.location.onLocationChange.observe { [weak self] locations in
                    guard let self = self, let coordinate = locations.last?.coordinate else { return }
                    self.lastUserLocation = coordinate
                    if self.hasPendingRecenter {
                        self.hasPendingRecenter = false
                        self.recenter(to: coordinate, zoom: self.pendingRecenterZoom)
                    }
                }
            }
        } else {
            mapView.location.options.puckType = nil
            locationObserver = nil
            lastUserLocation = nil
            hasPendingRecenter = false
            pendingRecenterZoom = nil
        }
    }

    /// Moves the camera to the device's current location. `zoom` NaN keeps the current zoom. If no
    /// fix is available yet, the request is deferred until the puck reports its first position.
    @objc public func recenterOnUserLocation(_ zoom: Double) {
        let targetZoom: Double? = zoom.isNaN ? nil : zoom
        if let coordinate = lastUserLocation {
            recenter(to: coordinate, zoom: targetZoom)
        } else {
            pendingRecenterZoom = targetZoom
            hasPendingRecenter = true
        }
    }

    private func recenter(to coordinate: CLLocationCoordinate2D, zoom: Double?) {
        let options = CameraOptions(
            center: coordinate,
            zoom: zoom ?? mapView.mapboxMap.cameraState.zoom
        )
        suppressCameraEvents = true
        setGesturesEnabled(false)
        mapView.camera.fly(to: options) { [weak self] _ in
            self?.suppressCameraEvents = false
            self?.setGesturesEnabled(true)
            self?.emitCameraChanged()
        }
    }

    /// Configures the compass ornament. `.adaptive` matches Android's default: the compass fades out
    /// while the map faces north and reappears after a rotate gesture. `position` selects the anchor
    /// corner (0 = top-leading, 1 = top-trailing, 2 = bottom-leading, 3 = bottom-trailing); the
    /// caller resolves the margins for that corner into `marginX` (inset from the horizontal edge)
    /// and `marginY` (inset from the vertical edge), matching Mapbox's `margins` CGPoint. Use them to
    /// clear app UI drawn over that corner (e.g. a floor selector, or map action buttons).
    @objc public func setCompass(enabled: Bool, position: Int32, marginX: Double, marginY: Double) {
        mapView.ornaments.options.compass.visibility = enabled ? .adaptive : .hidden
        mapView.ornaments.options.compass.position = Self.ornamentPosition(for: position)
        mapView.ornaments.options.compass.margins = CGPoint(x: marginX, y: marginY)
    }

    private static func ornamentPosition(for code: Int32) -> OrnamentPosition {
        switch code {
        case 0: return .topLeading
        case 2: return .bottomLeading
        case 3: return .bottomTrailing
        default: return .topTrailing
        }
    }

    @objc public func setBounds(minZoom: Double, maxZoom: Double) {
        let options = CameraBoundsOptions(
            bounds: nil,
            maxZoom: maxZoom.isNaN ? nil : maxZoom,
            minZoom: minZoom.isNaN ? nil : minZoom,
            maxPitch: nil,
            minPitch: nil
        )
        try? mapView.mapboxMap.setCameraBounds(with: options)
    }

    @objc public func fitBounds(
        swLatitude: Double,
        swLongitude: Double,
        neLatitude: Double,
        neLongitude: Double,
        paddingTop: Double,
        paddingLeft: Double,
        paddingBottom: Double,
        paddingRight: Double,
        bearing: Double
    ) {
        let coordinates = [
            CLLocationCoordinate2D(latitude: swLatitude, longitude: swLongitude),
            CLLocationCoordinate2D(latitude: neLatitude, longitude: neLongitude),
        ]
        // Clamp insets to the map size (mirrors Android's coerceToMapSize): opposite insets must
        // leave at least 1pt of viewport, otherwise camera(for:) throws and the fit is silently
        // dropped — which is why a large bottom-sheet inset had no effect on iOS.
        let maxHorizontal = max(0.0, (Double(mapView.bounds.width) - 1.0) / 2.0)
        let maxVertical = max(0.0, (Double(mapView.bounds.height) - 1.0) / 2.0)
        let padding = UIEdgeInsets(
            top: min(max(0.0, paddingTop), maxVertical),
            left: min(max(0.0, paddingLeft), maxHorizontal),
            bottom: min(max(0.0, paddingBottom), maxVertical),
            right: min(max(0.0, paddingRight), maxHorizontal)
        )
        guard let camera = try? mapView.mapboxMap.camera(
            for: coordinates,
            camera: CameraOptions(bearing: bearing.isNaN ? nil : bearing),
            coordinatesPadding: padding,
            maxZoom: nil,
            offset: nil
        ) else { return }
        // The first fit positions the freshly created map (which starts at a world view); jump
        // straight to the target instead of animating a long zoom-in flight. Later fits (floor
        // change, selection) keep the animation and its gesture lock.
        if !hasFitted {
            hasFitted = true
            suppressCameraEvents = true
            mapView.mapboxMap.setCamera(to: camera)
            suppressCameraEvents = false
            emitCameraChanged()
            return
        }
        suppressCameraEvents = true
        setGesturesEnabled(false)
        mapView.camera.fly(to: camera) { [weak self] _ in
            self?.suppressCameraEvents = false
            self?.setGesturesEnabled(true)
            self?.emitCameraChanged()
        }
    }

    @objc public func loadStyle(uri: String, completion: (() -> Void)?) {
        addedSourceIds.removeAll()
        addedLayerIds.removeAll()
        nextSourceIds.removeAll()
        nextLayerIds.removeAll()
        addedImageIds.removeAll()
        visibleLayerIds.removeAll()

        let resolved: StyleURI = {
            if uri.isEmpty { return .standard }
            return StyleURI(rawValue: uri) ?? .standard
        }()

        mapView.mapboxMap.loadStyle(resolved) { _ in
            completion?()
        }
    }

    @objc public func beginLayerSync() {
        nextSourceIds.removeAll()
        nextLayerIds.removeAll()
    }

    @objc public func finishLayerSync() {
        for layerId in addedLayerIds.subtracting(nextLayerIds) {
            if mapView.mapboxMap.layerExists(withId: layerId) {
                try? mapView.mapboxMap.removeLayer(withId: layerId)
            }
        }

        for sourceId in addedSourceIds.subtracting(nextSourceIds) {
            if mapView.mapboxMap.sourceExists(withId: sourceId) {
                try? mapView.mapboxMap.removeSource(withId: sourceId)
            }
        }

        addedLayerIds = nextLayerIds
        addedSourceIds = nextSourceIds
    }

    @objc public func addFillLayerByProperty(
        id: String,
        sourceId: String,
        geoJson: String,
        propertyName: String,
        colorKeys: [String],
        colorValues: [String],
        defaultColor: String,
        fillOpacity: Double
    ) {
        addGeoJsonSource(id: sourceId, geoJson: geoJson)
        nextLayerIds.insert(id)
        var matchExpr: [Any] = ["match", ["get", propertyName]]
        let pairCount = min(colorKeys.count, colorValues.count)
        for i in 0..<pairCount {
            matchExpr.append(colorKeys[i])
            matchExpr.append(colorValues[i])
        }
        matchExpr.append(defaultColor)
        let layerProps: [String: Any] = [
            "id": id,
            "type": "fill",
            "source": sourceId,
            "paint": [
                "fill-color": matchExpr,
                "fill-opacity": fillOpacity,
            ],
        ]
        do {
            if mapView.mapboxMap.layerExists(withId: id) {
                try mapView.mapboxMap.setLayerProperties(for: id, properties: layerProps)
            } else {
                try mapView.mapboxMap.addLayer(with: layerProps, layerPosition: nil)
            }
            addedLayerIds.insert(id)
        } catch {
            // ignore
        }
    }

    @objc public func addFillLayer(
        id: String,
        sourceId: String,
        geoJson: String,
        fillColor: String,
        fillOpacity: Double
    ) {
        addGeoJsonSource(id: sourceId, geoJson: geoJson)
        nextLayerIds.insert(id)
        let layerProps: [String: Any] = [
            "id": id,
            "type": "fill",
            "source": sourceId,
            "paint": [
                "fill-color": fillColor,
                "fill-opacity": fillOpacity,
            ],
        ]
        do {
            if mapView.mapboxMap.layerExists(withId: id) {
                try mapView.mapboxMap.setLayerProperties(for: id, properties: layerProps)
            } else {
                try mapView.mapboxMap.addLayer(with: layerProps, layerPosition: nil)
            }
            addedLayerIds.insert(id)
        } catch {
            // ignore — matches Android (best-effort apply)
        }
    }

    @objc public func addLineLayerFiltered(
        id: String,
        sourceId: String,
        geoJson: String,
        filterPropertyName: String,
        filterValue: String?,
        lineColor: String,
        lineWidth: Double
    ) {
        addGeoJsonSource(id: sourceId, geoJson: geoJson)
        nextLayerIds.insert(id)
        let filter: [Any] = if let value = filterValue {
            ["==", ["get", filterPropertyName], value]
        } else {
            ["==", ["literal", false], true]
        }
        let layerProps: [String: Any] = [
            "id": id,
            "type": "line",
            "source": sourceId,
            "filter": filter,
            // Round the selection outline (cap + join) to match the other platforms.
            "layout": [
                "line-cap": "round",
                "line-join": "round",
            ],
            "paint": [
                "line-color": lineColor,
                "line-width": lineWidth,
            ],
        ]
        do {
            if mapView.mapboxMap.layerExists(withId: id) {
                try mapView.mapboxMap.setLayerProperties(for: id, properties: layerProps)
            } else {
                try mapView.mapboxMap.addLayer(with: layerProps, layerPosition: nil)
            }
            addedLayerIds.insert(id)
        } catch {
            // ignore
        }
    }

    @objc public func addLineLayer(
        id: String,
        sourceId: String,
        geoJson: String,
        lineColor: String,
        lineWidth: Double
    ) {
        addGeoJsonSource(id: sourceId, geoJson: geoJson)
        nextLayerIds.insert(id)
        let layerProps: [String: Any] = [
            "id": id,
            "type": "line",
            "source": sourceId,
            "paint": [
                "line-color": lineColor,
                "line-width": lineWidth,
            ],
        ]
        do {
            if mapView.mapboxMap.layerExists(withId: id) {
                try mapView.mapboxMap.setLayerProperties(for: id, properties: layerProps)
            } else {
                try mapView.mapboxMap.addLayer(with: layerProps, layerPosition: nil)
            }
            addedLayerIds.insert(id)
        } catch {
            // ignore
        }
    }

    @objc public func addSymbolStyledLayer(
        id: String,
        sourceId: String,
        geoJson: String,
        layoutJson: String,
        paintJson: String
    ) {
        addGeoJsonSource(id: sourceId, geoJson: geoJson)
        nextLayerIds.insert(id)
        let layout = parsedObject(layoutJson)
        let paint = parsedObject(paintJson)
        var layerProps: [String: Any] = [
            "id": id,
            "type": "symbol",
            "source": sourceId,
        ]
        if !layout.isEmpty { layerProps["layout"] = layout }
        if !paint.isEmpty { layerProps["paint"] = paint }
        do {
            if mapView.mapboxMap.layerExists(withId: id) {
                try mapView.mapboxMap.setLayerProperties(for: id, properties: layerProps)
            } else {
                try mapView.mapboxMap.addLayer(with: layerProps, layerPosition: nil)
            }
            addedLayerIds.insert(id)
        } catch {
            // ignore
        }
    }

    @objc public func addFloorPlanImage(
        id: String,
        sourceId: String,
        url: String,
        ppmX: Double,
        ppmY: Double,
        originLat: Double,
        originLng: Double,
        angleDeg: Double
    ) {
        nextSourceIds.insert(sourceId)
        nextLayerIds.insert(id)
        if addedLayerIds.contains(id) { return }

        // Placeholder quad; real corners are applied once the image size is known.
        let placeholder: [[Double]] = [[0, 0], [0.0001, 0], [0.0001, -0.0001], [0, -0.0001]]
        do {
            if !mapView.mapboxMap.sourceExists(withId: sourceId) {
                var source = ImageSource(id: sourceId)
                source.url = url
                source.coordinates = placeholder
                try mapView.mapboxMap.addSource(source)
                addedSourceIds.insert(sourceId)
            }
            if !mapView.mapboxMap.layerExists(withId: id) {
                let layer = RasterLayer(id: id, source: sourceId)
                try mapView.mapboxMap.addLayer(layer)
                addedLayerIds.insert(id)
            }
        } catch {
            return
        }

        guard let imageUrl = URL(string: url) else { return }
        URLSession.shared.dataTask(with: imageUrl) { [weak self] data, _, _ in
            guard let self = self,
                  let data = data,
                  let image = UIImage(data: data) else { return }
            let widthPx = Int(image.size.width * image.scale)
            let heightPx = Int(image.size.height * image.scale)
            let coordinates = SPMapboxBridge.floorPlanCorners(
                widthPx: widthPx,
                heightPx: heightPx,
                ppmX: ppmX,
                ppmY: ppmY,
                originLat: originLat,
                originLng: originLng,
                angleDeg: angleDeg
            )
            DispatchQueue.main.async {
                try? self.mapView.mapboxMap.setSourceProperty(
                    for: sourceId,
                    property: "coordinates",
                    value: coordinates
                )
            }
        }.resume()
    }

    // Mirrors commonMain FloorPlanGeometry.corners — keep in sync.
    private static func floorPlanCorners(
        widthPx: Int,
        heightPx: Int,
        ppmX: Double,
        ppmY: Double,
        originLat: Double,
        originLng: Double,
        angleDeg: Double
    ) -> [[Double]] {
        if widthPx <= 0 || heightPx <= 0 || ppmX <= 0 || ppmY <= 0 {
            return [[0, 0], [0, 0], [0, 0], [0, 0]]
        }
        let widthMeters = Double(widthPx) / ppmX
        let heightMeters = Double(heightPx) / ppmY
        // Accurate WGS84 degree lengths (m); the flat 111320 constant was ~0.2% off and shifted the
        // floor plan off the vector layers. Keep in sync with commonMain FloorPlanGeometry.
        let latRad = originLat * .pi / 180.0
        let metersPerDegLat = 111132.92 - 559.82 * cos(2 * latRad) + 1.175 * cos(4 * latRad) - 0.0023 * cos(6 * latRad)
        let metersPerDegLng = 111412.84 * cos(latRad) - 93.5 * cos(3 * latRad) + 0.118 * cos(5 * latRad)
        func project(_ x: Double, _ y: Double) -> [Double] {
            let distance = (x * x + y * y).squareRoot()
            let azimuthDeg = 90.0 - (atan2(y, x) * 180.0 / .pi + angleDeg)
            let azimuth = azimuthDeg * .pi / 180.0
            let north = distance * cos(azimuth)
            let east = distance * sin(azimuth)
            let lat = originLat + north / metersPerDegLat
            let lng = originLng + east / metersPerDegLng
            return [lng, lat]
        }
        return [
            project(0, heightMeters),
            project(widthMeters, heightMeters),
            project(widthMeters, 0),
            project(0, 0),
        ]
    }

    @objc public func addRgbaImage(imageId: String, base64: String, width: Int, height: Int, scale: Double) {
        guard let image = SPMapboxBridge.imageFromRgba(base64, width: width, height: height, scale: scale) else { return }
        try? mapView.mapboxMap.removeImage(withId: imageId)
        try? mapView.mapboxMap.addImage(image, id: imageId)
    }

    /// Builds a UIImage from straight (non-premultiplied) RGBA bytes, matching the common pipeline.
    private static func imageFromRgba(_ base64: String, width: Int, height: Int, scale: Double) -> UIImage? {
        guard width > 0, height > 0,
              let data = Data(base64Encoded: base64) else { return nil }
        let bytesPerRow = width * 4
        guard data.count >= bytesPerRow * height else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        guard let provider = CGDataProvider(data: data as CFData),
              let cgImage = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: bytesPerRow,
                  space: colorSpace,
                  bitmapInfo: bitmapInfo,
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else { return nil }
        return UIImage(cgImage: cgImage, scale: scale > 0 ? CGFloat(scale) : 1.0, orientation: .up)
    }

    @objc public func orderLayers(_ ids: [String]) {
        // Re-stack our layers in the given order, so toggling layers on later doesn't put them
        // on top out of order. Each layer is moved above the previous existing one.
        var previous: String?
        for id in ids {
            guard mapView.mapboxMap.layerExists(withId: id) else { continue }
            if let prev = previous {
                try? mapView.mapboxMap.moveLayer(withId: id, to: .above(prev))
            }
            previous = id
        }
    }

    @objc public func setLayerIconSize(layerId: String, size: Double) {
        try? mapView.mapboxMap.setLayerProperty(for: layerId, property: "icon-size", value: size)
    }

    @objc public func setQueryableLayerIds(_ ids: [String]) {
        visibleLayerIds = ids
    }

    private func addGeoJsonSource(id: String, geoJson: String) {
        nextSourceIds.insert(id)
        guard !mapView.mapboxMap.sourceExists(withId: id) else {
            try? mapView.mapboxMap.setSourceProperty(for: id, property: "data", value: parsedGeoJson(geoJson))
            addedSourceIds.insert(id)
            return
        }
        // tolerance 0 disables Douglas-Peucker simplification in the native GeoJSON tiler
        // (geojson-vt-cpp). Without it, small round polygons (e.g. 1.5 m circles) collapse to an
        // octagon at high zoom, unlike the web SDK which keeps all vertices on the max-zoom tile.
        let sourceProps: [String: Any] = [
            "type": "geojson",
            "data": parsedGeoJson(geoJson),
            "tolerance": 0,
        ]
        do {
            try mapView.mapboxMap.addSource(withId: id, properties: sourceProps)
            addedSourceIds.insert(id)
        } catch {
            // ignore
        }
    }

    private func parsedObject(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return obj
    }

    private func parsedGeoJson(_ geoJson: String) -> Any {
        guard let data = geoJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return geoJson
        }
        return obj
    }

    private func queryFeatures(at point: CGPoint, coordinate: CLLocationCoordinate2D) {
        guard !visibleLayerIds.isEmpty else { return }
        let options = RenderedQueryOptions(layerIds: visibleLayerIds, filter: nil)
        _ = mapView.mapboxMap.queryRenderedFeatures(with: point, options: options) { [weak self] result in
            guard let self = self else { return }
            guard case .success(let features) = result, !features.isEmpty else { return }
            func rank(_ layerId: String) -> Int { self.visibleLayerIds.firstIndex(of: layerId) ?? -1 }
            let ranked = features.map { hit in (hit: hit, rank: hit.layers.map(rank).max() ?? -1) }
            guard let top = ranked.max(by: { $0.rank < $1.rank })?.hit else { return }
            let layerId = top.layers.max(by: { rank($0) < rank($1) }) ?? ""
            let feature = top.queriedFeature.feature
            let featureId = SPMapboxBridge.featureIdString(feature)
            let propertiesJson = SPMapboxBridge.encodeProperties(feature)
            self.onFeatureClicked?(
                layerId,
                featureId,
                propertiesJson,
                coordinate.latitude,
                coordinate.longitude
            )
        }
    }

    private static func featureIdString(_ feature: Feature) -> String? {
        guard let identifier = feature.identifier else { return nil }
        switch identifier {
        case .string(let s): return s
        case .number(let n): return String(n)
        }
    }

    private static func encodeProperties(_ feature: Feature) -> String? {
        guard let properties = feature.properties else { return nil }
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(properties),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }
}

extension SPMapboxBridge: GestureManagerDelegate {
    // Only a pan moves the camera away from the user's location; zoom/rotate keep the center.
    public func gestureManager(_ gestureManager: GestureManager, didBegin gestureType: GestureType) {
        if gestureType == .pan {
            onMapPanned?()
        }
    }

    public func gestureManager(_ gestureManager: GestureManager, didEnd gestureType: GestureType, willAnimate: Bool) {}

    public func gestureManager(_ gestureManager: GestureManager, didEndAnimatingFor gestureType: GestureType) {}
}

/// Swallows attribution link opens on kiosk devices — the menu itself (and its telemetry alert)
/// keeps working, only the external browser launch is suppressed.
private final class KioskAttributionURLOpener: AttributionURLOpener {
    func openAttributionURL(_ url: URL) {
        // Kiosk mode: never leave the app.
    }
}
