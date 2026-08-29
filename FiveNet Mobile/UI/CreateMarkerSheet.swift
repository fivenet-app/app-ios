import SwiftUI

/// Sheet for creating a new marker marker (zone/shape) on the livemap at a
/// tapped/hold position — or editing an existing marker (`marker` non-nil).
/// Reached from the LiveMap long-press gesture and gated by the
/// `livemap.LivemapService/CreateOrUpdateMarker` permission. Circles are the
/// natural "Sperrzone" shape; the server resolves the postal code from the
/// given position automatically.
struct CreateMarkerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let position: CGPoint
    let marker: Resources_Livemap_Markers_MarkerMarker?

    init(position: CGPoint, marker: Resources_Livemap_Markers_MarkerMarker? = nil) {
        self.position = position
        self.marker = marker
    }

    @State private var name = ""
    @State private var details = ""
    @State private var markerShape: MarkerShape = .circle
    @State private var color = Color.red
    @State private var radius = 20
    @State private var opacity = 20.0
    @State private var blinks = false
    @State private var iconName = "mdi:shield-outline"
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var isInitialized = false

    private enum MarkerShape: String, CaseIterable, Identifiable {
        case circle = "Kreis (Zone)"
        case icon = "Symbol"

        var id: String { rawValue }
    }

    private static let iconPresets = [
        "mdi:shield-outline", "mdi:shield-alert-outline", "mdi:alert-outline",
        "mdi:close-octagon-outline", "mdi:map-marker", "mdi:map-marker-radius-outline",
        "mdi:pine-tree", "mdi:car", "mdi:camera", "mdi:crosshairs"
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    MapPreviewView(worldPoint: effectivePosition, baseURL: appState.client?.baseURL)
                        .padding(.vertical, Theme.Spacing.xs)
                    HStack {
                        Label("Position", systemImage: "mappin.and.ellipse")
                        Spacer()
                        Text("\(Int(effectivePosition.x)), \(Int(effectivePosition.y))")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Markierung") {
                    TextField("Name", text: $name)
                    TextField("Beschreibung (optional)", text: $details, axis: .vertical)
                        .lineLimit(2...4)
                    Picker("Art", selection: $markerShape) {
                        ForEach(MarkerShape.allCases) { shape in
                            Text(shape.rawValue).tag(shape)
                        }
                    }
                    ColorPicker("Farbe", selection: $color, supportsOpacity: false)
                }

                Section(markerShape == .circle ? "Kreis-Eigenschaften" : "Symbol") {
                    switch markerShape {
                    case .circle:
                        Stepper("Radius: \(radius)", value: $radius, in: 5...75, step: 5)
                        HStack {
                            Text("Deckkraft")
                            Slider(value: $opacity, in: 1...75, step: 1)
                            Text("\(Int(opacity)) %")
                                .monospacedDigit()
                                .frame(width: 40, alignment: .trailing)
                                .foregroundStyle(.secondary)
                        }
                        Toggle("Blinkend", isOn: $blinks)
                    case .icon:
                        TextField("Icon-Name (z. B. mdi:shield-outline)", text: $iconName)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Theme.Spacing.md) {
                                ForEach(Self.iconPresets, id: \.self) { preset in
                                    let isSelected = iconName == preset
                                    Button {
                                        iconName = preset
                                    } label: {
                                        MapMarkerIconView(icon: preset, color: color, size: 36)
                                            .padding(Theme.Spacing.xs)
                                            .background(
                                                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                                    .fill(isSelected ? Theme.Palette.accent.opacity(0.15) : Color.clear)
                                                    .overlay(
                                                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                                                            .strokeBorder(isSelected ? Theme.Palette.accent : Color.clear, lineWidth: 1.5)
                                                    )
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Palette.danger)
                    }
                }
            }
            .navigationTitle(marker == nil ? "Markierung erstellen" : "Markierung bearbeiten")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear(perform: applyExistingMarker)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abbrechen") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await create() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            Text(marker == nil ? "Erstellen" : "Speichern")
                        }
                    }
                    .disabled(!canSubmit || isSaving)
                }
            }
        }
        .interactiveDismissDisabled(isSaving)
    }

    /// When editing, the marker keeps its existing position.
    private var effectivePosition: CGPoint {
        if let marker {
            return CGPoint(x: marker.x, y: marker.y)
        }
        return position
    }

    /// Transfers the existing marker's fields into the editable state once.
    private func applyExistingMarker() {
        guard let marker, !isInitialized else { return }
        isInitialized = true

        name = marker.name
        details = marker.description_p
        if marker.hasColor, let markerColor = Color(hex: marker.color) {
            color = markerColor
        }

        guard marker.hasData, let data = marker.data.data else { return }
        switch data {
        case .circle(let circle):
            markerShape = .circle
            radius = Int(circle.radius)
            opacity = Double(circle.opacity > 0 ? circle.opacity : 20)
            blinks = circle.blink
        case .icon(let icon):
            markerShape = .icon
            iconName = icon.icon.isEmpty ? Self.iconPresets[0] : icon.icon
        case .rectangle, .polygon, .polyline:
            break
        }
    }

    private var canSubmit: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.count <= 255 else { return false }
        switch markerShape {
        case .circle:
            return true
        case .icon:
            return !iconName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func create() async {
        guard canSubmit else { return }
        errorMessage = nil
        isSaving = true

        var marker = Resources_Livemap_Markers_MarkerMarker()
        marker.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        marker.x = effectivePosition.x
        marker.y = effectivePosition.y
        if let existing = self.marker {
            marker.id = existing.id
        }
        if !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            marker.description_p = details
        }
        marker.color = color.hexString ?? "#ef4444"
        marker.type = markerShape == .circle
            ? Resources_Livemap_Markers_MarkerType.circle
            : Resources_Livemap_Markers_MarkerType.icon

        var data = Resources_Livemap_Markers_MarkerData()
        switch markerShape {
        case .circle:
            var circle = Resources_Livemap_Markers_CircleMarker()
            circle.radius = Int32(radius)
            circle.opacity = Float(opacity)
            circle.stroke = true
            circle.strokeWidth = 3
            circle.blink = blinks
            data.circle = circle
        case .icon:
            var icon = Resources_Livemap_Markers_IconMarker()
            icon.icon = iconName.trimmingCharacters(in: .whitespacesAndNewlines)
            data.icon = icon
        }
        marker.data = data

        do {
            _ = try await appState.createOrUpdateMarker(marker)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isSaving = false
    }
}