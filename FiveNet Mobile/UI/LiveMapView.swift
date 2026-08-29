import SwiftUI

/// Livemap: live positions of on-duty colleagues ("UserMarker"), marker markers
/// (zones/shapes) and active dispatches. Offers list, map and units views like
/// the FiveNet web client.
///
/// The map renders the same San Andreas tiles as the FiveNet web app
/// (`/images/livemap/tiles/{postal|satellite}/{z}/{x}/{y}.webp`) using the
/// custom CRS from `app/composables/livemap/useMapProjection.ts`.
///
/// Dedicated route type so the marker links resolve against a destination
/// registered on this module root only. Sharing `CentrumRoute` with the
/// `CentrumView` module root registered two `navigationDestination`s for the
/// same type in one stack (white screen / double push).
enum LiveMapRoute: Hashable {
    case unit(Int64)
    case dispatch(Int64)
}

struct LiveMapView: View {
    /// Names the map viewport coordinate space in which the interactive
    /// control frames (zoom/menu) are measured for the tap hit-test.
    private static let mapControlFrameSpace = "mapViewport"

    @Environment(AppState.self) private var appState

    private enum ViewMode: String, CaseIterable, Identifiable {
        case duty = "Meine Einheit"
        case map = "Karte"
        case units = "Einheiten"

        var id: String { rawValue }
    }

    private enum MapTileLayer: String, CaseIterable, Identifiable {
        case postal = "postal"
        case satellite = "satellite"

        var id: String { rawValue }

        var label: String {
            switch self {
            case .postal: "Postleitzahl"
            case .satellite: "Satellit"
            }
        }

        var backgroundColor: Color {
            Color(hex: rawValue == "postal" ? "74aace" : "133e6b") ?? .blue
        }
    }

    @State private var viewMode: ViewMode = .map
    @AppStorage("livemapTileLayer") private var tileLayer: MapTileLayer = .postal
    @AppStorage("livemapMapZoom") private var mapZoom = MapProjection.minZoom
    @State private var startZoom = MapProjection.minZoom
    @State private var mapCenter = CGPoint(x: 2000, y: 2000)
    @State private var hasLoadedInitialCenter = false
    @State private var dragStart: (center: CGPoint, zoom: Int)?
    @AppStorage("livemapShowGrid") private var showGrid = false
    @AppStorage("livemapShowMarkerMarkers") private var showMarkerMarkers = true
    @AppStorage("livemapShowMarkerLabels") private var showMarkerLabels = true
    @State private var selectedMarker: Resources_Livemap_Markers_MarkerMarker?
    @AppStorage("livemapShowHeatmap") private var showHeatmap = false
    @State private var heatmapEntries: [Resources_Livemap_Heatmap_HeatmapEntry] = []
    @State private var longPressPosition: CGPoint?
    @State private var markerPosition: CGPoint?
    @State private var touchStartLocation: CGPoint?
    @State private var didLongPress = false
    @State private var showCreateDispatchSheet = false
    @State private var showCreateMarkerSheet = false
    @State private var mapControlFrames: [CGRect] = []

    init(initialTab: QuickAccessTab? = nil) {
        if let initialTab {
            switch initialTab {
            case .livemapDuty: _viewMode = State(initialValue: .duty)
            case .livemapUnits: _viewMode = State(initialValue: .units)
            default: _viewMode = State(initialValue: .map)
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Ansicht", selection: $viewMode) {
                ForEach(ViewMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, Theme.Spacing.md)

            Group {
                switch viewMode {
                case .duty:
                    MyDutyView()
                case .map:
                    tileMap
                case .units:
                    unitsTab
                }
            }
        }
        .background(Theme.Palette.background.ignoresSafeArea())
        .pendingAlarmBell()
        .moduleNavTitle(.livemap, title: viewMode == .duty ? "Meine Einheit" : nil)
        .navConnectionDot()
        .navigationDestination(for: LiveMapRoute.self) { route in
            switch route {
            case .unit(let id):
                UnitDetailView(unitID: id)
            case .dispatch(let id):
                DispatchDetailView(dispatchID: id)
            }
        }
        .sheet(item: $selectedMarker) { marker in
            MarkerMarkerDetailSheet(marker: marker)
        }
        .sheet(isPresented: $showCreateDispatchSheet) {
            CreateDispatchSheet(presetPosition: longPressPosition)
        }
        .sheet(isPresented: $showCreateMarkerSheet) {
            CreateMarkerSheet(position: markerPosition ?? .zero)
        }
        .task {
            if let baseURL = appState.client?.baseURL {
                await PostalLoader.shared.refresh(baseURL: baseURL)
            }
            await loadInitialCenterIfNeeded()
            await appState.startCentrumStream()
            await appState.startLivemapStream()
            if showHeatmap {
                await loadHeatmap()
            }
            var centrumTicks = 0
            while !Task.isCancelled {
                await appState.loadCentrum()
                // Low-frequency heatmap refresh: every 60 cycles (= 30 min)
                // plus the manual triggers (toggle on / initial load).
                centrumTicks += 1
                if showHeatmap && centrumTicks >= 60 {
                    centrumTicks = 0
                    await loadHeatmap()
                }
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onChange(of: showHeatmap) { _, isOn in
            if isOn {
                Task { await loadHeatmap() }
            } else {
                heatmapEntries = []
            }
        }
        .onDisappear {
            heatmapEntries = []
        }
        .alert("Livemap-Fehler", isPresented: Binding(
            get: { appState.livemapError != nil },
            set: { if !$0 { appState.clearLivemapError() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(appState.livemapError ?? "")
        }
    }

    // MARK: - Map view (San Andreas tiles)

    private var tileMap: some View {
        GeometryReader { proxy in
            let centerPixel = MapProjection.project(mapCenter, zoom: mapZoom)
            let viewportOrigin = CGPoint(
                x: centerPixel.x - proxy.size.width / 2,
                y: centerPixel.y - proxy.size.height / 2
            )
            let minTileX = Int(floor(viewportOrigin.x / MapProjection.tileSize))
            let maxTileX = Int(floor((viewportOrigin.x + proxy.size.width) / MapProjection.tileSize))
            let minTileY = Int(floor(viewportOrigin.y / MapProjection.tileSize))
            let maxTileY = Int(floor((viewportOrigin.y + proxy.size.height) / MapProjection.tileSize))

            ZStack {
                tileLayer.backgroundColor
                    .ignoresSafeArea()

                ForEach(minTileX...maxTileX, id: \.self) { tx in
                    ForEach(minTileY...maxTileY, id: \.self) { ty in
                        MapTileView(
                            url: tileURL(z: mapZoom, x: tx, y: ty),
                            backgroundColor: tileLayer.backgroundColor
                        )
                        .frame(width: MapProjection.tileSize, height: MapProjection.tileSize)
                        .position(
                            x: CGFloat(tx) * MapProjection.tileSize - viewportOrigin.x + MapProjection.tileSize / 2,
                            y: CGFloat(ty) * MapProjection.tileSize - viewportOrigin.y + MapProjection.tileSize / 2
                        )
                    }
                }

                if showGrid {
                    gridLayer(in: proxy.size, viewportOrigin: viewportOrigin)
                }

                if showHeatmap {
                    heatmapLayer(in: proxy.size, viewportOrigin: viewportOrigin)
                }

                if showMarkerMarkers {
                    markerMarkersLayer(in: proxy.size, viewportOrigin: viewportOrigin)
                }

                markerLayer(in: proxy.size, viewportOrigin: viewportOrigin)

                if appState.livemapMarkers.isEmpty && positionedDispatches.isEmpty && appState.livemapMarkerMarkers.isEmpty {
                    ContentUnavailableView(
                        "Keine Positionen",
                        systemImage: "map",
                        description: Text("Es sind gerade keine Kollegen oder Einsätze auf der Karte sichtbar.")
                    )
                }

                mapMenu
                    .padding()
                    .background(mapControlFrameReader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

                zoomControls
                    .padding()
                    .background(mapControlFrameReader)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
            .animation(.easeOut(duration: 0.2), value: mapZoom)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.mapControlFrameSpace)
            .onPreferenceChange(MapControlFramesPreferenceKey.self) { mapControlFrames = $0 }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .simultaneousGesture(tapAndLongPressGesture(viewportOrigin: viewportOrigin))
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private var mapMenu: some View {
        Menu {
            Picker("Kartenstil", selection: $tileLayer) {
                ForEach(MapTileLayer.allCases) { layer in
                    Text(layer.label).tag(layer)
                }
            }

            Toggle("Marker anzeigen", isOn: $showMarkerMarkers)
            Toggle("Markerbezeichnungen anzeigen", isOn: $showMarkerLabels)
                .disabled(!showMarkerMarkers)
            Toggle("Raster anzeigen", isOn: $showGrid)
            Toggle("Einsatz-Heatmap", isOn: $showHeatmap)

            Button {
                resetMap()
            } label: {
                Label("Karte zurücksetzen", systemImage: "arrow.clockwise")
            }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func resetMap() {
        mapZoom = MapProjection.minZoom
        startZoom = MapProjection.minZoom
        mapCenter = CGPoint(x: 2000, y: 2000)
    }

    private func tileURL(z: Int, x: Int, y: Int) -> URL {
        let base = appState.client?.baseURL
        return (base ?? URL(string: "https://localhost")!)
            .appendingPathComponent("images/livemap/tiles/\(tileLayer.rawValue)/\(z)/\(x)/\(y).webp")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 5)
            .onChanged { value in
                if dragStart == nil {
                    dragStart = (mapCenter, mapZoom)
                }
                guard let start = dragStart else { return }
                let startPixel = MapProjection.project(start.center, zoom: start.zoom)
                let currentPixel = CGPoint(
                    x: startPixel.x - value.translation.width,
                    y: startPixel.y - value.translation.height
                )
                mapCenter = clampCenter(MapProjection.unproject(currentPixel, zoom: mapZoom))
            }
            .onEnded { _ in
                dragStart = nil
            }
    }

    private var magnifyGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let target = startZoom + Int(log2(value).rounded())
                mapZoom = min(max(target, MapProjection.minZoom), MapProjection.maxZoom)
            }
            .onEnded { _ in
                startZoom = mapZoom
            }
    }

    /// Map gestures on empty ground (taps on markers are consumed by their own
/// handlers):
/// - Simple tap → "Einsatz erstellen" sheet at the tapped position.
/// - Long-press → "Markierung erstellen" sheet at the held position, only when
///   the character has the Livemap marker creation permission.
/// The location is captured by a simultaneous zero-distance drag
/// (a bare `TapGesture`/`LongPressGesture` has no location).
private func tapAndLongPressGesture(viewportOrigin: CGPoint) -> some Gesture {
    DragGesture(minimumDistance: 0)
        .onChanged { value in
            if touchStartLocation != value.startLocation {
                // A new touch begins: reset the long-press state so a previous
                // hold does not leak into this gesture.
                didLongPress = false
                touchStartLocation = value.startLocation
            }
        }
        .onEnded { value in
            // A tap: no real panning movement and no long-press happened.
            guard abs(value.translation.width) < 8, abs(value.translation.height) < 8,
                  !didLongPress,
                  let start = touchStartLocation,
                  !isOverMapControls(start),
                  !isOverAnyMarker(gamePoint: gamePoint(from: start, viewportOrigin: viewportOrigin), viewportOrigin: viewportOrigin)
            else { return }
            longPressPosition = gamePoint(from: start, viewportOrigin: viewportOrigin)
            showCreateDispatchSheet = true
        }
        .simultaneously(with: LongPressGesture(minimumDuration: 0.5)
            .onEnded { _ in
                handleMapLongPress(viewportOrigin: viewportOrigin)
            })
    }

    /// Long-press creates a marker marker (zone/shape) on empty ground,
    /// gated by the `CreateOrUpdateMarker` permission.
    private func handleMapLongPress(viewportOrigin: CGPoint) {
        guard canCreateMarkers,
              let start = touchStartLocation,
              !isOverMapControls(start),
              !isOverAnyMarker(gamePoint: gamePoint(from: start, viewportOrigin: viewportOrigin), viewportOrigin: viewportOrigin)
        else { return }
        didLongPress = true
        markerPosition = gamePoint(from: start, viewportOrigin: viewportOrigin)
        showCreateMarkerSheet = true
    }

    /// Whether the character may create marker markers on the livemap.
    private var canCreateMarkers: Bool {
        appState.can("livemap.LivemapService/CreateOrUpdateMarker")
    }

    /// Maps a view-space point (= the touch location relative to the map
    /// ZStack) to the clamped game-space point.
    private func gamePoint(from viewPoint: CGPoint, viewportOrigin: CGPoint) -> CGPoint {
        let pixel = CGPoint(x: viewPoint.x + viewportOrigin.x, y: viewPoint.y + viewportOrigin.y)
        return clampCenter(MapProjection.unproject(pixel, zoom: mapZoom))
    }

    /// Whether a view-space point lies on the map's interactive controls
    /// (zoom buttons / map menu). The tap & long-press map actions must not
    /// fire when the user is actually pressing one of those.
    private func isOverMapControls(_ point: CGPoint) -> Bool {
        mapControlFrames.contains { $0.insetBy(dx: -4, dy: -4).contains(point) }
    }

    /// Records a control's frame (in `mapControlFrameSpace`) so the map tap
    /// gesture can be suppressed there.
    private var mapControlFrameReader: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: MapControlFramesPreferenceKey.self,
                value: [geo.frame(in: .named(Self.mapControlFrameSpace))]
            )
        }
    }

    /// Whether a game-space point lies on a rendered marker (dispatch,
    /// colleague/user or marker marker). Map actions only fire on empty ground.
    private func isOverAnyMarker(gamePoint: CGPoint, viewportOrigin: CGPoint) -> Bool {
        let viewPoint = toView(gamePoint, viewportOrigin: viewportOrigin)

        for marker in appState.livemapMarkers {
            if distance(toView(CGPoint(x: marker.x, y: marker.y), viewportOrigin: viewportOrigin), viewPoint) < 20 {
                return true
            }
        }
        for dispatch in positionedDispatches {
            if distance(toView(CGPoint(x: dispatch.x, y: dispatch.y), viewportOrigin: viewportOrigin), viewPoint) < 24 {
                return true
            }
        }
        for marker in appState.livemapMarkerMarkers {
            if markerHitTest(marker, viewPoint: viewPoint, viewportOrigin: viewportOrigin) {
                return true
            }
        }
        return false
    }

    /// Hit-tests a marker marker against a view-space point, mirroring the
    /// rendered shapes (`markerMarkerShape`).
    private func markerHitTest(_ marker: Resources_Livemap_Markers_MarkerMarker, viewPoint: CGPoint, viewportOrigin: CGPoint) -> Bool {
        let anchor = toView(CGPoint(x: marker.x, y: marker.y), viewportOrigin: viewportOrigin)
        switch marker.type {
        case .dot:
            return distance(anchor, viewPoint) < 12
        case .circle:
            guard marker.hasData, let data = marker.data.data, case .circle(let circle) = data else { return false }
            let radius = max(4, CGFloat(circle.radius) * unitsToPixels)
            return distance(anchor, viewPoint) < radius + 2
        case .icon:
            return distance(anchor, viewPoint) < 24
        case .rectangle:
            guard marker.hasData, let data = marker.data.data, case .rectangle(let rectangle) = data else { return false }
            let end = toView(CGPoint(x: rectangle.endX, y: rectangle.endY), viewportOrigin: viewportOrigin)
            return viewPoint.x >= min(anchor.x, end.x) && viewPoint.x <= max(anchor.x, end.x)
                && viewPoint.y >= min(anchor.y, end.y) && viewPoint.y <= max(anchor.y, end.y)
        case .polygon:
            let points = shapePoints(marker).map { toView($0, viewportOrigin: viewportOrigin) }
            guard points.count >= 3 else { return false }
            return path(for: points, closed: true).contains(viewPoint)
        case .polyline:
            let points = shapePoints(marker).map { toView($0, viewportOrigin: viewportOrigin) }
            return distanceToPolyline(viewPoint, points) < 12
        case .unspecified, .UNRECOGNIZED:
            return false
        }
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func distanceToPolyline(_ point: CGPoint, _ points: [CGPoint]) -> CGFloat {
        guard points.count >= 2 else { return .greatestFiniteMagnitude }
        var best = CGFloat.greatestFiniteMagnitude
        for index in 0..<(points.count - 1) {
            best = min(best, distanceToSegment(point, points[index], points[index + 1]))
        }
        return best
    }

    private func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return distance(point, a) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return distance(point, CGPoint(x: a.x + t * dx, y: a.y + t * dy))
    }

    private func zoomBy(_ delta: Int) {
        startZoom = mapZoom
        let target = mapZoom + delta
        mapZoom = min(max(target, MapProjection.minZoom), MapProjection.maxZoom)
    }

    private var zoomControls: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Button {
                zoomBy(1)
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(mapZoom >= MapProjection.maxZoom)

            Button {
                zoomBy(-1)
            } label: {
                Image(systemName: "minus")
                    .frame(width: 34, height: 34)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(mapZoom <= MapProjection.minZoom)
        }
    }

    private func clampCenter(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, -4000), 8000),
            y: min(max(point.y, -4000), 8000)
        )
    }

    /// Centers the map on Los Santos (postal 7135) once, so the initial view
    /// is not the bare tile origin (2000/2000).
    private func loadInitialCenterIfNeeded() async {
        guard !hasLoadedInitialCenter else { return }
        hasLoadedInitialCenter = true
        guard let baseURL = appState.client?.baseURL,
              let postal = await PostalLoader.shared.location(for: "7135", baseURL: baseURL) else { return }
        mapCenter = clampCenter(CGPoint(x: postal.x, y: postal.y))
    }

    // MARK: - Map overlays

    /// Projects a game-space point into view coordinates.
    private func toView(_ point: CGPoint, viewportOrigin: CGPoint) -> CGPoint {
        let p = MapProjection.project(point, zoom: mapZoom)
        return CGPoint(x: p.x - viewportOrigin.x, y: p.y - viewportOrigin.y)
    }

    /// Game units to screen pixels at the current zoom level.
    private var unitsToPixels: Double {
        MapProjection.scaleX * pow(2, Double(mapZoom))
    }

    private func markerLayer(in size: CGSize, viewportOrigin: CGPoint) -> some View {
        ZStack {
            ForEach(positionedDispatches) { dispatch in
                let p = toView(CGPoint(x: dispatch.x, y: dispatch.y), viewportOrigin: viewportOrigin)
                dispatchMarkerView(dispatch)
                    .position(x: p.x, y: p.y)
            }

            ForEach(appState.livemapMarkers) { marker in
                let p = toView(CGPoint(x: marker.x, y: marker.y), viewportOrigin: viewportOrigin)
                userMarkerView(marker)
                    .position(x: p.x, y: p.y)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Dispatches that carry map coordinates (x/y != 0).
    private var positionedDispatches: [Resources_Centrum_Dispatches_Dispatch] {
        appState.dispatches.filter { $0.x != 0 || $0.y != 0 }
    }

    // MARK: Marker markers (zones / shapes)

    private func markerMarkersLayer(in size: CGSize, viewportOrigin: CGPoint) -> some View {
        ZStack {
            ForEach(appState.livemapMarkerMarkers) { marker in
                markerMarkerShape(marker, viewportOrigin: viewportOrigin)
            }
            if showMarkerLabels {
                ForEach(appState.livemapMarkerMarkers) { marker in
                    markerMarkerLabel(marker, viewportOrigin: viewportOrigin)
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    /// Draws the marker shape with a precise hit area. The tap target is the
    /// shape itself; labels are drawn separately so they cannot swallow taps.
    @ViewBuilder
    private func markerMarkerShape(_ marker: Resources_Livemap_Markers_MarkerMarker, viewportOrigin: CGPoint) -> some View {
        let color = markerMarkerColor(marker)
        let origin = CGPoint(x: marker.x, y: marker.y)
        let anchor = toView(origin, viewportOrigin: viewportOrigin)

        switch marker.type {
        case .dot:
            Circle()
                .fill(.white)
                .frame(width: 14, height: 14)
                .overlay {
                    Circle()
                        .stroke(.black, lineWidth: 1.5)
                }
                .contentShape(Circle())
                .onTapGesture { selectedMarker = marker }
                .position(x: anchor.x, y: anchor.y)
        case .circle:
            if marker.hasData {
                let radius = max(4, CGFloat(marker.data.circle.radius) * unitsToPixels)
                Circle()
                    .fill(color.opacity(markerFillOpacity(marker)))
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: radius * 2, height: radius * 2)
                    .contentShape(Circle())
                    .onTapGesture { selectedMarker = marker }
                    .overlay {
                        if marker.data.circle.blink {
                            // Overlay VOR .position: Der Blip wird so am
                            // Kreiszentrum zentriert (Overlay legt sich auf den
                            // radius^2-Rahmen). Hinter .position läge er im
                            // full-size-Container und wäre markierzentriert.
                            BlinkMarkerBlipView(color: color, zoom: mapZoom)
                        }
                    }
                    .position(x: anchor.x, y: anchor.y)
            }
        case .icon:
            iconMarker(marker, color: color, anchor: anchor)
        case .rectangle:
            if marker.hasData {
                let end = toView(CGPoint(x: marker.data.rectangle.endX, y: marker.data.rectangle.endY), viewportOrigin: viewportOrigin)
                let width = abs(end.x - anchor.x)
                let height = abs(end.y - anchor.y)
                let center = CGPoint(x: min(anchor.x, end.x) + width / 2, y: min(anchor.y, end.y) + height / 2)
                Rectangle()
                    .fill(color.opacity(markerFillOpacity(marker)))
                    .stroke(color, lineWidth: 1.5)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
                    .onTapGesture { selectedMarker = marker }
                    .position(x: center.x, y: center.y)
            }
        case .polygon, .polyline:
            let points = shapePoints(marker).map { toView($0, viewportOrigin: viewportOrigin) }
            if points.count >= 2 {
                let shape = path(for: points, closed: marker.type == .polygon)
                shape
                    .fill(marker.type == .polygon ? color.opacity(markerFillOpacity(marker)) : Color.clear)
                    .stroke(color, lineWidth: 2)
                    .contentShape(shape)
                    .onTapGesture { selectedMarker = marker }
            }
        case .unspecified, .UNRECOGNIZED:
            EmptyView()
        }
    }

    /// The name label of a marker marker, placed in view coordinates.
    @ViewBuilder
    private func markerMarkerLabel(_ marker: Resources_Livemap_Markers_MarkerMarker, viewportOrigin: CGPoint) -> some View {
        if !marker.name.isEmpty {
            switch marker.type {
            case .dot, .icon:
                EmptyView()
            case .circle, .rectangle, .polygon, .polyline, .unspecified, .UNRECOGNIZED:
                let point = markerLabelPoint(marker, viewportOrigin: viewportOrigin)
                Text(marker.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .position(x: point.x, y: point.y)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Where to place a marker marker's name label (view coordinates).
    private func markerLabelPoint(_ marker: Resources_Livemap_Markers_MarkerMarker, viewportOrigin: CGPoint) -> CGPoint {
        let anchor = toView(CGPoint(x: marker.x, y: marker.y), viewportOrigin: viewportOrigin)
        guard marker.hasData, let data = marker.data.data else { return anchor }
        switch data {
        case .rectangle(let rectangle):
            let end = toView(CGPoint(x: rectangle.endX, y: rectangle.endY), viewportOrigin: viewportOrigin)
            return CGPoint(x: (anchor.x + end.x) / 2, y: (anchor.y + end.y) / 2)
        case .polygon(let polygon):
            return centroid(of: polygon.points.map { toView(CGPoint(x: $0.x, y: $0.y), viewportOrigin: viewportOrigin) }, fallback: anchor)
        case .polyline(let polyline):
            return centroid(of: polyline.points.map { toView(CGPoint(x: $0.x, y: $0.y), viewportOrigin: viewportOrigin) }, fallback: anchor)
        case .circle, .icon:
            return anchor
        }
    }

    private func centroid(of points: [CGPoint], fallback: CGPoint) -> CGPoint {
        guard !points.isEmpty else { return fallback }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private func markerFillOpacity(_ marker: Resources_Livemap_Markers_MarkerMarker) -> Double {
        guard marker.hasData, let data = marker.data.data else { return 0.15 }
        let raw: Float
        switch data {
        case .circle(let circle): raw = circle.opacity
        case .rectangle(let rectangle): raw = rectangle.opacity
        case .polygon(let polygon): raw = polygon.opacity
        case .icon, .polyline: raw = 0
        }
        let value = raw <= 0 ? 15 : raw
        return Double(value) / 100
    }

    private func iconMarker(_ marker: Resources_Livemap_Markers_MarkerMarker, color: Color, anchor: CGPoint) -> some View {
        VStack(spacing: 1) {
            MapMarkerIconView(icon: markerIconName(marker), color: .white, size: 12)
                .frame(width: 20, height: 20)
                .background(color, in: Circle())
                .shadow(radius: 1)
            if showMarkerLabels && !marker.name.isEmpty {
                Text(marker.name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { selectedMarker = marker }
        .position(x: anchor.x, y: anchor.y)
    }

    private func markerIconName(_ marker: Resources_Livemap_Markers_MarkerMarker) -> String {
        guard marker.hasData, let data = marker.data.data, case .icon(let icon) = data else {
            return "mdi:map-marker-question"
        }
        return icon.icon.isEmpty ? "mdi:map-marker-question" : icon.icon
    }

    private func shapePoints(_ marker: Resources_Livemap_Markers_MarkerMarker) -> [CGPoint] {
        var points = [CGPoint(x: marker.x, y: marker.y)]
        guard marker.hasData, let data = marker.data.data else { return points }
        switch data {
        case .polygon(let polygon):
            points.append(contentsOf: polygon.points.map { CGPoint(x: $0.x, y: $0.y) })
        case .polyline(let polyline):
            points.append(contentsOf: polyline.points.map { CGPoint(x: $0.x, y: $0.y) })
        default:
            break
        }
        return points
    }

    private func path(for points: [CGPoint], closed: Bool) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        if closed {
            path.closeSubpath()
        }
        return path
    }

    // MARK: Grid

    private func gridLayer(in size: CGSize, viewportOrigin: CGPoint) -> some View {
        let interval = gridInterval(for: mapZoom)
        let lower = CGPoint(x: -4000, y: -4000)
        let upper = CGPoint(x: 8000, y: 8000)
        let minX = floor(lower.x / interval) * interval
        let maxX = ceil(upper.x / interval) * interval
        let minY = floor(lower.y / interval) * interval
        let maxY = ceil(upper.y / interval) * interval

        return Canvas { context, _ in
            var x = minX
            while x <= maxX {
                let start = toView(CGPoint(x: x, y: minY), viewportOrigin: viewportOrigin)
                let end = toView(CGPoint(x: x, y: maxY), viewportOrigin: viewportOrigin)
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                context.stroke(line, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
                x += interval
            }
            var y = minY
            while y <= maxY {
                let start = toView(CGPoint(x: minX, y: y), viewportOrigin: viewportOrigin)
                let end = toView(CGPoint(x: maxX, y: y), viewportOrigin: viewportOrigin)
                var line = Path()
                line.move(to: start)
                line.addLine(to: end)
                context.stroke(line, with: .color(.black.opacity(0.35)), lineWidth: 0.5)
                y += interval
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func gridInterval(for zoom: Int) -> Double {
        switch zoom {
        case 1: return 1000
        case 2...3: return 500
        case 4...5: return 250
        case 6...7: return 100
        default: return 500
        }
    }

    // MARK: Heatmap

    /// Renders the dispatch heatmap as overlapping radial-gradient hotspots.
    /// Each entry is a weighted point (x/y in game space, w = intensity); the
    /// hotspot radius and opacity are normalized against the strongest entry.
    private func heatmapLayer(in size: CGSize, viewportOrigin: CGPoint) -> some View {
        let maxWeight = heatmapEntries.map(\.w).max() ?? 1
        return ZStack {
            ForEach(heatmapEntries.indices, id: \.self) { index in
                let entry = heatmapEntries[index]
                let point = toView(CGPoint(x: entry.x, y: entry.y), viewportOrigin: viewportOrigin)
                let intensity = maxWeight > 0 ? min(max(Double(entry.w) / Double(maxWeight), 0), 1) : 0
                let radius = 12 + 40 * intensity
                let opacity = 0.18 + 0.4 * intensity
                Circle()
                    .fill(RadialGradient(
                        colors: [
                            Color.orange.opacity(opacity),
                            Color.red.opacity(opacity * 0.6),
                            .clear,
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: radius
                    ))
                    .frame(width: radius * 2, height: radius * 2)
                    .position(x: point.x, y: point.y)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }

    private func loadHeatmap() async {
        guard let client = appState.client else { return }
        do {
            let response = try await client.getDispatchHeatmap()
            heatmapEntries = response.entries
        } catch {
            heatmapEntries = []
        }
    }

    // MARK: Markers (user / dispatch)

    @ViewBuilder
    private func userMarkerView(_ marker: Resources_Livemap_Markers_UserMarker) -> some View {
        let label = VStack(spacing: 2) {
            Circle()
                .fill(markerColor(marker))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle()
                        .stroke(.white, lineWidth: 2)
                }
                .shadow(radius: 2)
            if marker.hasUnit {
                unitMarkerLabel(marker.unit)
            } else {
                Text(markerName(marker))
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }

        if marker.hasUnit {
            // Tapping a colleague that is part of a unit opens the unit info.
            NavigationLink(value: LiveMapRoute.unit(marker.unit.id)) {
                label
            }
            .buttonStyle(.plain)
        } else {
            label
        }
    }

    /// Label for a marker whose user belongs to a unit: the unit's alias with a
    /// status-colored dot instead of the colleague's full name.
    private func unitMarkerLabel(_ unit: Resources_Centrum_Units_Unit) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(unit.status.status.color)
                .frame(width: 5, height: 5)
            Text(unit.initials.isEmpty ? unit.name : unit.initials)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
    }

    private func dispatchMarkerView(_ dispatch: Resources_Centrum_Dispatches_Dispatch) -> some View {
        // Dedicated (typed) route instead of a bare Int64 so the marker tap
        // resolves unambiguously in the enclosing stack (bare Int64 collides
        // with the Wiki page destination and can double-push a module).
        NavigationLink(value: LiveMapRoute.dispatch(dispatch.id)) {
            VStack(spacing: 2) {
                Image(systemName: "bell.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(dispatch.status.status.color.readableText)
                    .frame(width: 22, height: 22)
                    .background(dispatch.status.status.color, in: Circle())
                    .shadow(radius: 2)
                Text(formatDispatchID(dispatch.id))
                    .font(.caption2.bold().monospacedDigit())
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            }
        }
        .buttonStyle(.plain)
    }

    private func markerName(_ marker: Resources_Livemap_Markers_UserMarker) -> String {
        let override = marker.data.nameOverride
        if marker.hasData, marker.data.hasNameOverride, !override.firstname.isEmpty || !override.lastname.isEmpty {
            let name = [override.firstname, override.lastname].filter { !$0.isEmpty }.joined(separator: " ")
            if !name.isEmpty { return name }
        }
        let user = marker.user
        let name = [user.firstname, user.lastname].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Benutzer #\(marker.userID)" : name
    }

    private func markerColor(_ marker: Resources_Livemap_Markers_UserMarker) -> Color {
        Color(hex: marker.color) ?? .accentColor
    }

    private func markerMarkerColor(_ marker: Resources_Livemap_Markers_MarkerMarker) -> Color {
        marker.hasColor ? (Color(hex: marker.color) ?? .accentColor) : .accentColor
    }

    // MARK: - Units tab

    private var unitsTab: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 10)], spacing: 10) {
                ForEach(sortedUnits) { unit in
                    UnitTileView(unit: unit)
                }
            }
            .padding(.horizontal)
            .padding(.top, 4)
        }
        .overlay {
            if appState.units.isEmpty {
                ContentUnavailableView(
                    "Keine Einheiten",
                    systemImage: "building.2",
                    description: Text("Es sind keine Einheiten verfügbar.")
                )
            }
        }
    }

    /// All units, favorites first.
    private var sortedUnits: [Resources_Centrum_Units_Unit] {
        let favorites = appState.favoriteUnitIDs
        return appState.units.sorted { lhs, rhs in
            let l = favorites.contains(lhs.id)
            let r = favorites.contains(rhs.id)
            if l != r { return l }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

// MARK: - Marker marker details

/// Radar-style pulse for "blinking" circle markers, mirroring the web
/// `MarkerBlinkBlip.vue`: three fixed concentric rings that flash in sequence,
/// with a slight per-ring stagger (delayed phase). Ring size scales down when
/// the map is below the base zoom, exactly like the web power law (but clamped
/// to a small visible minimum so the pulse stays noticeable on our low default
/// zoom).
private struct BlinkMarkerBlipView: View {
    let color: Color
    let zoom: Int

    private let ringSizes: [CGFloat] = [64, 80, 96]
    private let ringWidth: CGFloat = 4
    private let pulseDuration: Double = 2.0
    private let pulseDelay: Double = 0.45
    private let baseZoom: Int = 5

    /// The rings scale with the zoom level exactly like the zone circle does
    /// (`2^(zoom − baseZoom)`), so the outermost ring always sits on the zone
    /// edge at every zoom step (web keeps a fixed 64–96 px decorative blip and
    /// only shrinks it below baseZoom 5 — on the app that made the pulse too
    /// big at low zooms and too small from zoom 6 on; per user feedback the
    /// halo now tracks the marker). The stroke shrinks/grows with the same
    /// factor (web applies it as a CSS `transform` that includes the border).
    private var scaleFactor: CGFloat {
        pow(2.0, Double(zoom - baseZoom))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { context in
            let now = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(Array(ringSizes.enumerated()), id: \.offset) { index, size in
                    let phase = (now + Double(index) * pulseDelay)
                        .truncatingRemainder(dividingBy: pulseDuration)
                        / pulseDuration
                    Circle()
                        .stroke(color, lineWidth: ringWidth * scaleFactor)
                        .frame(width: size * scaleFactor, height: size * scaleFactor)
                        .opacity(blipOpacity(for: phase))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Web keyframes: 0 %→0.18, 6 %→1.0, 12 %→0.68, 18 %→0.24, 100 %→0.18
    /// (linear between the points, easing back before the loop restarts).
    private func blipOpacity(for phase: Double) -> Double {
        switch phase {
        case 0.0...0.06:
            return 0.18 + (1.0 - 0.18) * (phase / 0.06)
        case 0.06...0.12:
            return 1.0 - (1.0 - 0.68) * ((phase - 0.06) / 0.06)
        case 0.12...0.18:
            return 0.68 - (0.68 - 0.24) * ((phase - 0.12) / 0.06)
        default:
            return 0.24 + (0.18 - 0.24) * ((phase - 0.18) / 0.82)
        }
    }
}

/// Detail sheet for a marker marker (zone/area): name, description, expiry and
/// creator. Mirrors the web `MarkerMarkerPopup`: edit is offered when the
/// `CreateOrUpdateMarker` permission + Access attribute allow it, delete when
/// the `DeleteMarker` permission + public-marker rules pass.
private struct MarkerMarkerDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let marker: Resources_Livemap_Markers_MarkerMarker

    @State private var showEditor = false
    @State private var showDeleteConfirm = false
    @State private var isDeleting = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        headerIcon
                        VStack(alignment: .leading, spacing: 2) {
                            Text(marker.name.isEmpty ? "Markierung #\(marker.id)" : marker.name)
                                .font(.headline)
                            Text(marker.type.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if marker.hasDescription_p, !marker.description_p.isEmpty {
                    Section("Beschreibung") {
                        Text(marker.description_p)
                            .font(.subheadline)
                    }
                }

                Section("Details") {
                    detailRow("Postleitzahl", marker.postal.isEmpty ? "k.A." : marker.postal)
                    if let expires = marker.expiry {
                        detailRow("Läuft ab am", formatTimestamp(expires))
                    }
                    detailRow("Erstellt von", creatorName)
                    detailRow("Erstellt am", formatTimestamp(marker.createdAt))
                    detailRow("Job", marker.jobLabel.isEmpty ? "k.A." : marker.jobLabel)
                }
            }
            .navigationTitle("Markierung")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isMarkerEditableShape, canEdit {
                        Button {
                            showEditor = true
                        } label: {
                            Label("Bearbeiten", systemImage: "pencil")
                        }
                    }
                    if canDelete {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Löschen", systemImage: "trash")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fertig") { dismiss() }
                }
            }
            .sheet(isPresented: $showEditor) {
                CreateMarkerSheet(
                    position: CGPoint(x: marker.x, y: marker.y),
                    marker: marker
                )
            }
            .confirmationDialog(
                "Markierung löschen?",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Löschen", role: .destructive) {
                    Task { await performDelete() }
                }
                Button("Abbrechen", role: .cancel) {}
            } message: {
                Text("Die Markierung „\(marker.name)“ wird endgültig gelöscht.")
            }
            .alert("Fehler", isPresented: isErrorPresented) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "Unbekannter Fehler")
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Access gates (mirror the web MarkerMarkerPopup + helpers.ts)

    /// The editor only supports circle/icon markers; other shapes keep their
    /// tap-only detail sheet (no destructive type change).
    private var isMarkerEditableShape: Bool {
        marker.type == .circle || marker.type == .icon
    }

    private var markerIsPublic: Bool {
        marker.hasPublic && marker.public
    }

    private var markerCreatorIsMe: Bool {
        let me = appState.activeCharacterUserID
        if marker.hasCreatorID && marker.creatorID == me { return true }
        if marker.hasCreator && marker.creator.userID == me { return true }
        return false
    }

    /// Web `canMutatePublicMarker`: non-public markers are always mutable,
    /// public ones only for superusers or members of the marker's own job.
    private var canMutatePublicMarker: Bool {
        if !markerIsPublic { return true }
        if appState.isSuperuser { return true }
        guard let job = appState.character?.job, !job.isEmpty else { return false }
        return marker.job == job
    }

    /// Web `checkIfCanEditMarker` against the `Access` attribute (empty list
    /// means creator-only, mirroring the server's `CheckIfHasOwnJobAccess`).
    private var canEdit: Bool {
        guard appState.can("livemap.LivemapService/CreateOrUpdateMarker") else { return false }
        guard canMutatePublicMarker else { return false }
        if appState.isSuperuser { return true }
        guard marker.hasCreator else { return false }

        let fields = appState.attrStringList("livemap.LivemapService/CreateOrUpdateMarker", key: "Access")
        if fields.isEmpty { return markerCreatorIsMe }
        if fields.contains("Any") { return true }
        if fields.contains("Lower_Rank"), let creator = marker.creatorOrNil {
            if creator.jobGrade < (appState.character?.jobGrade ?? 0) { return true }
        }
        if fields.contains("Same_Rank"), let creator = marker.creatorOrNil {
            if creator.jobGrade <= (appState.character?.jobGrade ?? 0) { return true }
        }
        if fields.contains("Own") { return markerCreatorIsMe }
        return false
    }

    /// Web `canDeletePublicMarker`: non-public markers are always deletable,
    /// public ones need `Own` on the creator or `Any` within the marker's job.
    private var canDelete: Bool {
        guard appState.can("livemap.LivemapService/DeleteMarker") else { return false }
        if !markerIsPublic { return true }
        if appState.isSuperuser { return true }

        let fields = appState.attrStringList("livemap.LivemapService/DeleteMarker", key: "Access")
        if fields.contains("Own"), markerCreatorIsMe { return true }
        guard let job = appState.character?.job, !job.isEmpty else { return false }
        return marker.job == job && fields.contains("Any")
    }

    private var isErrorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { newValue in
            if !newValue { errorMessage = nil }
        })
    }

    private func performDelete() async {
        guard !isDeleting else { return }
        isDeleting = true
        errorMessage = nil
        do {
            try await appState.deleteMarker(id: marker.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isDeleting = false
    }

    private var markerColor: Color {
        marker.hasColor ? (Color(hex: marker.color) ?? .accentColor) : .accentColor
    }

    /// Shown in the header: the marker's own icon marker with the icon,
    /// or a plain colored circle when the marker has no icon.
    @ViewBuilder
    private var headerIcon: some View {
        if marker.type == .icon {
            MapMarkerIconView(icon: detailIconName, color: markerColor, size: 22)
                .frame(width: 44, height: 44)
                .background(markerColor.opacity(0.15), in: Circle())
        } else {
            Circle()
                .fill(markerColor)
                .frame(width: 40, height: 40)
        }
    }

    private var detailIconName: String {
        guard marker.hasData, let data = marker.data.data, case .icon(let icon) = data else {
            return "mdi:map-marker-question"
        }
        return icon.icon.isEmpty ? "mdi:map-marker-question" : icon.icon
    }

    private var creatorName: String {
        guard marker.hasCreator else { return "Unbekannt" }
        let name = [marker.creator.firstname, marker.creator.lastname].filter { !$0.isEmpty }.joined(separator: " ")
        return name.isEmpty ? "Unbekannt" : name
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
    }
}

extension Resources_Livemap_Markers_MarkerMarker {
    /// Convenience expiry accessor.
    var expiry: Resources_Timestamp_Timestamp? {
        hasExpiresAt ? expiresAt : nil
    }

    /// Convenience whether a creator is present, unwrapping the accessor the
    /// generated type stores.
    var creatorOrNil: Resources_Users_Short_UserShort? {
        hasCreator ? creator : nil
    }
}

private struct MapControlFramesPreferenceKey: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

// MARK: - Map projection (mirrors FiveNet's custom CRS)

private enum MapProjection {
    static let scaleX: Double = 0.02072
    static let scaleY: Double = 0.0205
    static let centerX: Double = 117.3
    static let centerY: Double = 172.8
    static let tileSize: Double = 256
    static let minZoom = 1
    static let maxZoom = 7

    static func project(_ point: CGPoint, zoom: Int) -> CGPoint {
        let scale = pow(2.0, Double(zoom))
        return CGPoint(
            x: (point.x * scaleX + centerX) * scale,
            y: (point.y * -scaleY + centerY) * scale
        )
    }

    static func unproject(_ pixel: CGPoint, zoom: Int) -> CGPoint {
        let scale = pow(2.0, Double(zoom))
        return CGPoint(
            x: (pixel.x / scale - centerX) / scaleX,
            y: (pixel.y / scale - centerY) / -scaleY
        )
    }
}

extension Resources_Livemap_Markers_MarkerType {
    var label: String {
        switch self {
        case .unspecified: return "Unbekannt"
        case .dot: return "Punkt"
        case .circle: return "Kreis"
        case .icon: return "Symbol"
        case .rectangle: return "Rechteck"
        case .polygon: return "Polygon"
        case .polyline: return "Polylinie"
        case .UNRECOGNIZED: return "Unbekannt"
        }
    }
}

// MARK: - Tile loading

/// Loads a single map tile from the FiveNet server with an in-memory cache
/// plus an on-disk cache (Library/Caches/FiveNetTiles/), keyed by the tile URL.
private struct MapTileView: View {
    let url: URL
    let backgroundColor: Color

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            backgroundColor
            if let image {
                Image(uiImage: image)
                    .resizable()
            }
        }
        .task(id: url) {
            image = await MapTileCache.shared.image(for: url)
        }
    }
}

@MainActor
private final class MapTileCache {
    static let shared = MapTileCache()

    private let memoryCache = NSCache<NSURL, UIImage>()

    private static var diskDirectory: URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = caches.appendingPathComponent("FiveNetTiles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func diskFileURL(for url: URL) -> URL? {
        guard let dir = diskDirectory else { return nil }
        let host = url.host ?? "localhost"
        let path = url.path.replacingOccurrences(of: "/", with: "_")
        return dir.appendingPathComponent(host + path)
    }

    func image(for url: URL) async -> UIImage? {
        if let hit = memoryCache.object(forKey: url as NSURL) {
            return hit
        }
        if let fileURL = Self.diskFileURL(for: url),
           let data = await Self.readData(from: fileURL),
           let diskImage = UIImage(data: data) {
            memoryCache.setObject(diskImage, forKey: url as NSURL)
            return diskImage
        }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = UIImage(data: data) else { return nil }
            memoryCache.setObject(image, forKey: url as NSURL)
            if let fileURL = Self.diskFileURL(for: url) {
                Self.write(data, to: fileURL)
            }
            return image
        } catch {
            return nil
        }
    }

    private nonisolated static func readData(from url: URL) async -> Data? {
        await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
    }

    private nonisolated static func write(_ data: Data, to url: URL) {
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

#Preview {
    NavigationStack {
        LiveMapView()
            .environment(AppState())
    }
}
