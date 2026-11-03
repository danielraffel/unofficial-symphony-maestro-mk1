import SwiftUI
import AppKit
import ApplicationServices
import CoreAudio
import CoreGraphics
import MaestroCore
import MaestroDevice


// MARK: - Feature Views

/// Preference key to measure analog strip height for aligning ADAT/DIGITAL sections.
struct AnalogStripHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Dropdown pill with bordered container, hover chevron, and tooltip.
/// Uses Button(.plain) + native NSMenu — guarantees FULL-AREA click targets.
/// On macOS, Menu(.borderlessButton) only hits text content, not backgrounds.
/// Button(.plain) hits all visible content inside its label (same fix as toggleButton).
/// On hover: background lightens, border strengthens, chevron appears at end.
struct PillMenu: View {
    let text: String
    var highlight: Bool = false
    var highlightColor: Color = .purple
    var fontSize: CGFloat = 8
    var pillHeight: CGFloat = 18
    var toolTip: String = ""
    let options: [(String, () -> Void)]
    @State private var isHovered = false

    var body: some View {
        Button {
            showNativeMenu()
        } label: {
            // Background INSIDE label — full-area hit testing on macOS.
            // Button(.plain) only hits visible content; background inside
            // the label counts as visible content and expands the click area.
            // ZStack: text is perfectly centered independent of the chevron,
            // which floats at the trailing edge and only appears on hover.
            ZStack {
                Text(text)
                    .font(.system(size: fontSize, weight: .medium))
                    .lineLimit(1)

                HStack {
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: max(6, fontSize - 1), weight: .medium))
                        .opacity(isHovered ? 0.5 : 0)
                        .padding(.trailing, 3)
                }
            }
            .foregroundStyle(highlight ? highlightColor : .primary)
            .frame(maxWidth: .infinity)
            .frame(height: pillHeight)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.controlBackgroundColor))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(highlight
                            ? highlightColor.opacity(isHovered ? 0.22 : 0.15)
                            : Color.primary.opacity(isHovered ? 0.12 : 0.06))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(highlight
                        ? highlightColor.opacity(isHovered ? 0.6 : 0.5)
                        : Color.primary.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(toolTip)
    }

    private func showNativeMenu() {
        // A native menu should also commit and dismiss any active TextField
        // edit elsewhere in the mixer. Without this, the old label keeps its
        // insertion/selection highlight while the menu is open.
        NSApp.keyWindow?.endEditing(for: nil)
        NSApp.keyWindow?.makeFirstResponder(nil)
        let menu = NSMenu()
        for (label, action) in options {
            let item = NSMenuItem(title: label, action: #selector(PillMenuTarget.fire), keyEquivalent: "")
            let target = PillMenuTarget(action)
            item.target = target
            item.representedObject = target  // prevent ARC dealloc during menu display
            // Show checkmark next to the currently selected item
            if label == text {
                item.state = .on
            }
            menu.addItem(item)
        }
        // popUp is synchronous — blocks until menu dismissed, then actions fire
        if let event = NSApp.currentEvent, let contentView = event.window?.contentView {
            let point = contentView.convert(event.locationInWindow, from: nil)
            menu.popUp(positioning: nil, at: point, in: contentView)
        }
    }
}

/// Target-action bridge for NSMenuItem → Swift closure.
private class PillMenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
}

// MARK: - Custom Controls

/// Rotary knob control inspired by Logic Pro's pan/send knobs.
/// 270° arc indicator, vertical-drag interaction, Shift for fine mode,
/// double-click value label to type a number.
///
/// Evidence: `og_source/maestro2/App/Views/APRotaryKnobControl.m` — 270° arc, blue fill
/// Face colours for the knob body and fader thumb.
///
/// These are deliberately NOT `Color(.controlColor)` / `Color(.controlBackgroundColor)`.
/// Those are AppKit *dynamic* colours: they carry both appearances and pick one
/// by resolving against `NSAppearance.current` at the moment they are asked for a
/// concrete value. A plain `.fill(Color(.controlColor))` is fine, because SwiftUI
/// resolves it against the view's environment. Inside a `Gradient` it is not --
/// gradient stops are flattened to concrete colours when the gradient is built,
/// and if that happens on a path where `NSAppearance.current` is not the window's
/// appearance, the stop freezes to the wrong appearance's value.
/// `NSColor.controlColor` in dark mode is very nearly black, which is exactly the
/// reported symptom: black knob faces in a light-mode window, intermittently,
/// while every other colour stayed correct -- the arc, track and pointer are
/// SwiftUI-native and resolve normally.
///
/// Driving the stops from `@Environment(\.colorScheme)` keeps them inside the
/// SwiftUI colour pipeline, where they re-resolve with the view.
enum ControlFace {
    /// Which appearance these faces should actually be drawn for.
    ///
    /// `@Environment(\.colorScheme)` is the normal source and is correct for
    /// ordinary view content. It is NOT reliable for the knobs in
    /// `MonitorToolbarView`, which SwiftUI hosts in the window's `NSToolbar`
    /// rather than in the detail pane's view tree. Those knobs have twice been
    /// reported drawing their dark-mode face in a light-mode window
    /// (2026-09-11, 2026-09-14), and the pointer -- which came from
    /// `Color.primary` -- inverted along with it. Two independent colours
    /// flipping together is only possible if that subtree resolved
    /// `colorScheme` as `.dark`, so the environment value itself is what goes
    /// wrong, not the gradient flattening that `7ceef18` fixed.
    ///
    /// The state is intermittent: it did not reproduce here across window
    /// activation, backgrounding, or a full system light -> dark -> light round
    /// trip, so it cannot be fixed by chasing the trigger.
    ///
    /// `NSApp.effectiveAppearance` is the authoritative value and does not
    /// depend on where a view is hosted. In the normal case it agrees with the
    /// environment and nothing changes; when the environment is wrong, this is
    /// still right. The environment value is still passed in and used as the
    /// fallback for the one case AppKit cannot answer (no `NSApp` yet, e.g. in
    /// a preview or a unit test).
    @MainActor
    static func resolve(_ environmentScheme: ColorScheme, appearance: AppAppearance) -> ColorScheme {
        // Read the explicit choice before AppKit: SwiftUI may update this subtree
        // before ContentView has applied the matching NSApp appearance.
        if let selectedScheme = appearance.colorScheme { return selectedScheme }
        guard let app = NSApp else { return environmentScheme }
        return app.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .dark
            : .light
    }

    /// Posted by the system when the user switches light/dark. Views that cache
    /// a resolved scheme re-resolve on this, because a stale environment may
    /// not re-render them on its own.
    static var appearanceChanged: NotificationCenter.Publisher {
        DistributedNotificationCenter.default().publisher(
            for: Notification.Name("AppleInterfaceThemeChangedNotification"))
    }

    /// Pointer/indicator colour for a knob face.
    ///
    /// Deliberately derived from the same scheme as the face rather than from
    /// `Color.primary`, so the pointer can never end up the same tone as the
    /// face it is drawn on -- it stays legible even if the scheme is wrong.
    static func pointer(_ scheme: ColorScheme) -> Color {
        (scheme == .dark ? Color.white : Color.black).opacity(0.75)
    }

    static func knobBody(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(white: 0.34), Color(white: 0.22)]
            : [Color(white: 1.00), Color(white: 0.86)]
    }

    static func faderThumb(_ scheme: ColorScheme) -> [Color] {
        scheme == .dark
            ? [Color(white: 0.34), Color(white: 0.24), Color(white: 0.34)]
            : [Color(white: 1.00), Color(white: 0.88), Color(white: 1.00)]
    }
}

/// Keeps a view's cached face appearance in step with the real one.
///
/// Seeds on appear, re-resolves whenever the environment changes (the normal
/// path), and again on the system light/dark notification — that last one
/// matters because a stale environment may never change, and so would never
/// re-render the view on its own.
@MainActor
private struct ResolvedFaceScheme: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .auto
    @Binding var scheme: ColorScheme

    func body(content: Content) -> some View {
        content
            .onAppear { resolveScheme() }
            .onChange(of: colorScheme) { _, _ in resolveScheme() }
            .onChange(of: appearance) { _, _ in
                // Let the root clear NSApp.appearance when switching back to Auto.
                DispatchQueue.main.async { resolveScheme() }
            }
            .onReceive(ControlFace.appearanceChanged) { _ in
                // NSApp.effectiveAppearance is updated on the same runloop pass
                // that delivers this, so re-read after it rather than during.
                DispatchQueue.main.async { resolveScheme() }
            }
    }

    private func resolveScheme() {
        scheme = ControlFace.resolve(colorScheme, appearance: appearance)
    }
}

extension View {
    /// See `ControlFace.resolve` for why this exists.
    func resolvingFaceScheme(into scheme: Binding<ColorScheme>) -> some View {
        modifier(ResolvedFaceScheme(scheme: scheme))
    }
}

struct RotaryKnobView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let label: String
    let unit: String
    var size: CGFloat = 44
    var defaultValue: Double? = nil
    var arcColor: Color = Color(red: 0.52, green: 0.69, blue: 0.98) // Legacy blue #85AFFB
    /// When true, arc draws from center outward (for pan/balance controls).
    var bipolar: Bool = false
    /// When true, the built-in value readout is hidden (managed externally by parent view).
    var externalReadout: Bool = false
    /// Called only when the USER moves the knob (not on external binding updates).
    /// Use this instead of onChange(of: value) to avoid double-writes when the binding
    /// is updated externally (e.g. volume keys changing speakerLevel during a drag).
    var onUserChange: ((Double) -> Void)? = nil
    /// Called with delta when Option+Drag (batch pan mode). Parent applies to all targets.
    var onBatchDrag: ((Double) -> Void)? = nil
    /// Called once at drag start when Option is held (for snapshotting start pans).
    var onBatchDragStart: (() -> Void)? = nil
    /// Called on Option+click. When set, overrides the default reset-to-defaultValue behavior.
    var onOptionClick: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// Appearance the knob face is drawn for. Resolved from AppKit rather than
    /// taken straight from the environment -- see `ControlFace.resolve`.
    @State private var faceScheme: ColorScheme = .light

    @State private var isDragging = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var dragStartValue: Double = 0

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    /// The angle (in degrees) corresponding to the current value on the 270° arc.
    /// -225° = 7 o'clock (min), -90° = 12 o'clock (center), +45° = 5 o'clock (max).
    private var valueAngle: Double {
        -225 + normalizedValue * 270
    }

    /// The center angle of the arc (12 o'clock) = -90°.
    private var centerAngle: Double { -90 }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            ZStack {
                // Background track (gray arc)
                ArcShape(startAngle: -225, endAngle: 45, lineWidth: 3)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 3)
                    .frame(width: size, height: size)

                // Value arc (colored)
                if bipolar {
                    // Bipolar: arc from center (12 o'clock) to current value
                    let arcStart = min(centerAngle, valueAngle)
                    let arcEnd = max(centerAngle, valueAngle)
                    if abs(valueAngle - centerAngle) > 0.5 {
                        ArcShape(
                            startAngle: arcStart,
                            endAngle: arcEnd,
                            lineWidth: 3
                        )
                        .stroke(arcColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: size, height: size)
                    }
                } else {
                    // Unipolar: arc from min (7 o'clock) to current value
                    ArcShape(
                        startAngle: -225,
                        endAngle: valueAngle,
                        lineWidth: 3
                    )
                    .stroke(arcColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .frame(width: size, height: size)
                }

                // Center detent mark (bipolar/pan knobs only) — a notch on the
                // track at 12 o'clock so "centered" is unmistakable at a glance.
                if bipolar {
                    Capsule()
                        .fill(Color.gray.opacity(0.6))
                        .frame(width: 2, height: 5)
                        .offset(y: -(size / 2 - 1.5))
                }

                // Knob body — adaptive for light/dark mode
                Circle()
                    .fill(
                        RadialGradient(
                            colors: ControlFace.knobBody(faceScheme),
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: size * 0.4
                        )
                    )
                    .frame(width: size * 0.6, height: size * 0.6)
                    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)

                // Position indicator — a short pointer from the knob body toward
                // the current value. Driven by the same resolved scheme as the
                // face, so it always contrasts against it. Points straight up
                // at center.
                Capsule()
                    .fill(ControlFace.pointer(faceScheme))
                    .frame(width: 2.5, height: size * 0.22)
                    .offset(y: -(size * 0.19))
                    .rotationEffect(.degrees(-135 + normalizedValue * 270))
            }
            // Without this the knob is hit-tested against its drawn pixels, so
            // the transparent gap between the arc and the knob face ignored
            // drags. See GenerousHitArea.
            .contentShape(GenerousHitArea(dx: 6, dy: 6))
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        if !isDragging {
                            isDragging = true
                            dragStartValue = value
                            // Snapshot batch start pans if Option held
                            if NSEvent.modifierFlags.contains(.option) {
                                onBatchDragStart?()
                            }
                        }
                        let sensitivity: Double = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1.0
                        let delta = -gesture.translation.height * sensitivity
                        let span = range.upperBound - range.lowerBound
                        let newValue = dragStartValue + (delta / 150) * span
                        value = (newValue / step).rounded() * step
                        value = min(max(value, range.lowerBound), range.upperBound)
                        onUserChange?(value)
                        // Option+Drag: forward delta to batch handler
                        if NSEvent.modifierFlags.contains(.option), let batch = onBatchDrag {
                            batch(value - dragStartValue)
                        }
                    }
                    .onEnded { _ in isDragging = false }
            )
            .onTapGesture(count: 2) {
                // Double-tap knob to reset to default
                if let def = defaultValue {
                    value = def
                    onUserChange?(value)
                }
            }
            .simultaneousGesture(
                TapGesture()
                    .modifiers(.option)
                    .onEnded { _ in
                        if let handler = onOptionClick {
                            handler()
                        } else if let def = defaultValue {
                            value = def
                            onUserChange?(value)
                        }
                    }
            )

            // Value readout — double-click to edit, text pre-selected
            if !externalReadout {
                if isEditing {
                    TextField("", text: $editText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: size + 8)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let parsed = Double(editText) {
                                value = min(max(parsed, range.lowerBound), range.upperBound)
                                value = (value / step).rounded() * step
                            }
                            isEditing = false
                        }
                        .onExitCommand { isEditing = false }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                            }
                        }
                } else {
                    Text(formatValue())
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(isDragging ? .primary : .secondary)
                        .onTapGesture(count: 2) {
                            editText = String(format: step >= 1 ? "%.0f" : "%.1f", value)
                            isEditing = true
                        }
                }
            }
        }
        .frame(width: size + 16)
        .resolvingFaceScheme(into: $faceScheme)
    }

    private func formatValue() -> String {
        let numStr = step >= 1 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        return "\(numStr) \(unit)"
    }
}

/// Hit-testing area for the faders and knobs, deliberately larger than what is
/// drawn.
///
/// Two separate problems this solves.
///
/// The fader thumb OVER-TRAVELS: `thumbY` runs from `-overTravel` at maximum to
/// `usableHeight - overTravel` at minimum, so at either extreme roughly 11.5 pt
/// of the thumb sits outside the `GeometryReader`'s bounds. A plain
/// `.contentShape(Rectangle())` is clipped to those bounds, so the protruding
/// part of the thumb was visible but not grabbable -- worst exactly at 0 dB and
/// at the floor, which are the positions users park a fader at.
///
/// The knobs had no `contentShape` at all, so hit-testing fell back to the drawn
/// pixels: the arc stroke and the small centre circle were draggable, and the
/// transparent gap between them was not.
///
/// Expanding by a negative inset keeps layout untouched -- the frame, and so the
/// meter alignment across a rack, is unchanged; only the interactive region
/// grows. Horizontal growth is kept smaller than vertical because a fader's
/// neighbours are side by side, and where the shapes do overlap the later
/// sibling in the stack wins anyway.
struct GenerousHitArea: Shape {
    var dx: CGFloat
    var dy: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(rect.insetBy(dx: -dx, dy: -dy))
    }
}

/// Arc shape for RotaryKnobView — draws a circular arc.
struct ArcShape: Shape {
    var startAngle: Double // degrees, 0 = right, -90 = top
    var endAngle: Double
    var lineWidth: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2 - lineWidth / 2
        var path = Path()
        path.addArc(center: center, radius: radius,
                     startAngle: .degrees(startAngle),
                     endAngle: .degrees(endAngle),
                     clockwise: false)
        return path
    }
}

/// Vertical fader control inspired by Logic Pro's channel faders.
/// Click-and-drag, Shift for fine mode, double-click readout to type value,
/// Option-click to reset to default.
///
/// Evidence: `og_source/maestro2/App/Views/APFaderControl.m` — vertical slider with knob image
struct FaderView: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let defaultValue: Double
    var height: CGFloat = 140
    var showScale: Bool = true
    /// When true, the value readout is hidden (managed externally by parent view).
    var externalReadout: Bool = false
    /// Called with delta when Option+Drag (batch fader mode). Parent applies to all targets.
    var onBatchDrag: ((Double) -> Void)? = nil
    /// Called once at drag start when Option is held (for snapshotting start levels).
    var onBatchDragStart: (() -> Void)? = nil
    /// Called for user-driven changes, including Option-click reset.
    var onUserChange: ((Double) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// See `RotaryKnobView.faceScheme`.
    @State private var faceScheme: ColorScheme = .light

    @State private var isDragging = false
    @State private var isEditing = false
    @State private var editText = ""
    @State private var dragStartValue: Double = 0
    @State private var dragStartY: CGFloat = 0
    /// The value on the other side of the last completed fader move. A
    /// double-click on the fader swaps to it, so a second double-click can
    /// toggle back without introducing a separate undo control.
    @State private var previousValue: Double?

    private let trackWidth: CGFloat = 5
    var thumbHeight: CGFloat = 24
    var thumbWidth: CGFloat = 28

    private var normalizedValue: Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return (value - range.lowerBound) / span
    }

    /// Whether the fader is currently being dragged (exposed for external readout styling).
    var dragging: Bool { isDragging }

    /// Extra travel beyond the normal range so the thumb center reaches
    /// the very top and bottom of the adjacent LED meter.
    private let overTravel: CGFloat = 11.5

    var body: some View {
        VStack(spacing: 0) {
            // Value readout — double-click to edit, text pre-selected
            if !externalReadout {
                if isEditing {
                    TextField("", text: $editText)
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 40)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            if let parsed = Double(editText) {
                                value = min(max(parsed, range.lowerBound), range.upperBound)
                                value = (value / step).rounded() * step
                            }
                            isEditing = false
                        }
                        .onExitCommand { isEditing = false }
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
                            }
                        }
                } else {
                    Text(String(format: step >= 1 ? "%.0f" : "%.1f", value))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(isDragging ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(width: 40)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.primary.opacity(0.06))
                        )
                        .onTapGesture(count: 2) {
                            editText = String(format: step >= 1 ? "%.0f" : "%.1f", value)
                            isEditing = true
                        }
                }
            }

            // Fader body — .top alignment ensures fader track top aligns with adjacent meter top
            // (scale canvas is taller due to labelPad; without .top, center alignment pushes track down)
            HStack(alignment: .top, spacing: 2) {
                // Scale markings
                if showScale {
                    faderScale
                }

                // Track + Thumb — overTravel extends the usable range so the thumb
                // center line aligns with the very top/bottom of the adjacent meter.
                GeometryReader { geo in
                    let usableHeight = geo.size.height - thumbHeight + overTravel * 2
                    let thumbY = -overTravel + usableHeight * (1 - normalizedValue)

                    ZStack(alignment: .top) {
                        // Track groove — adaptive
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(.separatorColor))
                            .frame(width: trackWidth, height: geo.size.height)
                            .frame(maxWidth: .infinity)

                        // Filled portion (below thumb)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.3, green: 0.6, blue: 1.0), Color(red: 0.2, green: 0.4, blue: 0.8)],
                                    startPoint: .bottom,
                                    endPoint: .top
                                )
                            )
                            .frame(width: trackWidth, height: geo.size.height - thumbY - thumbHeight / 2)
                            .offset(y: thumbY + thumbHeight / 2)
                            .frame(maxWidth: .infinity)

                        // Thumb / Cap — adaptive
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: ControlFace.faderThumb(faceScheme),
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: thumbWidth, height: thumbHeight)
                            .overlay(
                                // Center line on thumb
                                Rectangle()
                                    .fill(Color.white.opacity(0.4))
                                    .frame(width: thumbWidth - 8, height: 1)
                            )
                            .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                            .offset(y: thumbY)
                            .frame(maxWidth: .infinity)
                    }
                    // Generous, and taller than the bounds so the over-travelled
                    // thumb stays grabbable at both extremes. See GenerousHitArea.
                    .contentShape(GenerousHitArea(dx: 10, dy: overTravel + 8))
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !isDragging {
                                    isDragging = true
                                    dragStartValue = value
                                    previousValue = value
                                    dragStartY = gesture.startLocation.y
                                    // Snapshot batch start levels if Option held
                                    if NSEvent.modifierFlags.contains(.option) {
                                        onBatchDragStart?()
                                    }
                                }
                                let sensitivity: Double = NSEvent.modifierFlags.contains(.shift) ? 0.25 : 1.0
                                let deltaY = (dragStartY - gesture.location.y) * sensitivity
                                let span = range.upperBound - range.lowerBound
                                let newValue = dragStartValue + (deltaY / Double(usableHeight)) * span
                                value = (newValue / step).rounded() * step
                                value = min(max(value, range.lowerBound), range.upperBound)
                                onUserChange?(value)
                                // Option+Drag: forward delta to batch handler
                                if NSEvent.modifierFlags.contains(.option), let batch = onBatchDrag {
                                    batch(value - dragStartValue)
                                }
                            }
                            .onEnded { _ in isDragging = false }
                    )
                    .onTapGesture(count: 2) {
                        guard let previousValue else { return }
                        let currentValue = value
                        value = previousValue
                        self.previousValue = currentValue
                        onUserChange?(value)
                    }
                    .simultaneousGesture(
                        TapGesture()
                            .modifiers(.option)
                            .onEnded { _ in
                                previousValue = value
                                value = defaultValue
                                onUserChange?(defaultValue)
                            }
                    )
                }
                .frame(width: thumbWidth + 4, height: height)
            }

        }
        .resolvingFaceScheme(into: $faceScheme)
    }

    /// Canvas-drawn fader scale with major/minor tick hierarchy.
    /// Major ticks get labels + long marks; minor ticks get short marks only.
    /// Emphasis on unity/default value (0 for gain, 0 for trim).
    @ViewBuilder
    private var faderScale: some View {
        let major = majorMarks()
        let minor = minorMarks()
        // Extra height so top/bottom labels aren't clipped by Canvas frame
        let labelPad: CGFloat = 6
        Canvas { context, size in
            let h = size.height - labelPad * 2
            let span = range.upperBound - range.lowerBound
            guard span > 0 else { return }
            // Match the extended travel range used by the thumb
            let usable = h - CGFloat(thumbHeight) + overTravel * 2
            let topPad = CGFloat(thumbHeight) / 2 - overTravel + labelPad

            for val in major {
                let norm = (val - range.lowerBound) / span
                let y = topPad + usable * CGFloat(1 - norm)
                let isDefault = abs(val - defaultValue) < 0.01
                let lineWidth: CGFloat = isDefault ? 1.0 : 0.5
                let tickLen: CGFloat = isDefault ? 8 : 6
                let opacity: Double = isDefault ? 0.7 : 0.4

                // Tick mark
                var tick = Path()
                tick.move(to: CGPoint(x: size.width - tickLen, y: y))
                tick.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(tick, with: .color(.gray.opacity(opacity)), lineWidth: lineWidth)

                // Label
                let label = formatDB(val)
                let text = Text(label)
                    .font(.system(size: isDefault ? 8 : 7.5, weight: isDefault ? .semibold : .regular, design: .monospaced))
                    .foregroundColor(.gray.opacity(isDefault ? 0.9 : 0.6))
                context.draw(text, at: CGPoint(x: size.width - tickLen - 2, y: y), anchor: .trailing)
            }

            for val in minor {
                let norm = (val - range.lowerBound) / span
                let y = topPad + usable * CGFloat(1 - norm)

                var tick = Path()
                tick.move(to: CGPoint(x: size.width - 3, y: y))
                tick.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(tick, with: .color(.gray.opacity(0.25)), lineWidth: 0.5)
            }
        }
        .frame(width: 24, height: height + labelPad * 2)
        .offset(y: -labelPad) // shift up so marks align with meter segments
    }

    /// Major scale marks — labeled with tick + number.
    private func majorMarks() -> [Double] {
        if range.lowerBound == -2 && range.upperBound == 2 {
            return [-2, -1, 0, 1, 2]
        } else if range.lowerBound == -48 && range.upperBound == 0 {
            // Matches Input/Output meter scale: every 6 dB from -48 to 0
            return [-48, -42, -36, -30, -24, -18, -12, -6, 0]
        } else if range.lowerBound == -48 && range.upperBound == 6 {
            return [-48, -42, -36, -30, -24, -18, -12, -6, 0, 6]
        } else if range.lowerBound == -64 && range.upperBound == 0 {
            return [-64, -48, -36, -24, -12, 0]
        } else if range.upperBound == 85 {
            return [0, 10, 20, 40, 60, 85]
        }
        let step = (range.upperBound - range.lowerBound) / 4
        return stride(from: range.lowerBound, through: range.upperBound, by: step).map { $0 }
    }

    /// Minor scale marks — short ticks only (no labels).
    private func minorMarks() -> [Double] {
        let majors = Set(majorMarks())
        if range.lowerBound == -2 && range.upperBound == 2 {
            return [-1.5, -0.5, 0.5, 1.5].filter { !majors.contains($0) }
        } else if range.upperBound == 85 {
            return [5, 15, 30, 50, 70].filter { !majors.contains($0) }
        } else if range.lowerBound == -48 && range.upperBound == 0 {
            return [-45, -39, -33, -27, -21, -15, -9, -3].filter { !majors.contains($0) }
        } else if range.lowerBound == -48 && range.upperBound == 6 {
            return [-45, -39, -33, -27, -21, -15, -9, -3, 3].filter { !majors.contains($0) }
        } else if range.lowerBound == -64 && range.upperBound == 0 {
            return [-56, -42, -30, -18, -6].filter { !majors.contains($0) }
        }
        return []
    }

    private func formatDB(_ db: Double) -> String {
        if db == range.lowerBound && db < -50 { return "-∞" }
        return String(format: "%.0f", db)
    }
}

/// LED-style level meter inspired by Logic Pro's channel meters.
/// Segmented LEDs with green/yellow/orange/red zones, peak hold indicator.
/// Optional dB scale markings (Logic-style: 0,3,6,9,12,15,18,21,24,30,35,40,45,50,60).
///
/// Evidence: `og_source/maestro2/App/Views/APAudioMeterView.m` — 32-segment LED meter
struct LEDMeterView: View {
    let level: Double   // dBFS (e.g. -48..0 or -60..0)
    let peak: Double    // dBFS (peak hold)
    let label: String
    var height: CGFloat = 140
    var width: CGFloat = 8
    var showScale: Bool = false
    /// When true, scale is drawn on the left side of the meter (between fader and meter).
    var scaleOnLeft: Bool = false
    /// Meter range in dB below 0. Default 60 = -60..0 dBFS. Use 48 for A/D converter meters.
    var rangeDB: Double = 60
    /// When true, unlit segments show a muted version of their zone color.
    var showZoneColoring: Bool = false
    /// Horizontal offset for the label text (e.g. to nudge L closer to R in Master strip).
    var labelOffsetX: CGFloat = 0
    /// Vertical offset for the label text.
    var labelOffsetY: CGFloat = 0

    private let segmentCount = 24
    private let segmentGap: CGFloat = 1
    private var scale: MeterScale { MeterScale(rangeDB: rangeDB, segmentCount: segmentCount) }

    /// Major dB marks (labeled) for the scale, computed from rangeDB.
    private var majorMarks: [Int] {
        if rangeDB == 48 {
            // A/D converter: every 6 dB, labeled with minus signs
            return [0, 6, 12, 18, 24, 30, 36, 42, 48]
        }
        // Default: Logic Pro-style for -60 to 0
        return [0, 3, 6, 9, 12, 15, 18, 21, 24, 30, 35, 40, 45, 50, 60]
    }

    /// Minor dB marks (tick only, no label) for perceptual density near 0 dB.
    private var minorMarks: [Int] {
        if rangeDB == 48 {
            return [3, 9]  // extra ticks near 0 for perceptual density
        }
        return []
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 0) {
                // Scale on left side (between fader and meter)
                if showScale && scaleOnLeft {
                    meterScaleCanvas(leftSide: true)
                }

                // LED segments
                if width > 0 {
                    let peakSegment = scale.peakSegment(forDB: peak)
                    VStack(spacing: segmentGap) {
                        ForEach((0..<segmentCount).reversed(), id: \.self) { i in
                            let segmentDB = dBForSegment(i)
                            let isLit = level >= segmentDB
                            let isPeak = peakSegment == i

                            RoundedRectangle(cornerRadius: 1)
                                .fill(isLit || isPeak
                                    ? colorForSegment(i)
                                    : (showZoneColoring
                                        ? colorForSegment(i).opacity(0.15)
                                        : Color(.separatorColor).opacity(0.5)))
                                .frame(width: width, height: segmentHeight)
                                .opacity(isPeak && !isLit ? 0.7 : 1.0)
                        }
                    }
                    .frame(height: height)
                }

                // Scale on right side (default)
                if showScale && !scaleOnLeft {
                    meterScaleCanvas(leftSide: false)
                }
            }

            // Label
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .offset(x: labelOffsetX, y: labelOffsetY)
            }
        }
    }

    /// Canvas-drawn dB scale aligned to the very top and bottom of the meter.
    /// The canvas is slightly taller than the meter to prevent label clipping at extremes.
    private let scalePad: CGFloat = 5  // extra space top/bottom for label text

    @ViewBuilder
    private func meterScaleCanvas(leftSide: Bool) -> some View {
        Canvas { context, size in
            let h = size.height
            // Inset by scalePad so labels at 0 dB (top) and -rangeDB (bottom) aren't clipped
            let topY: CGFloat = scalePad + segmentHeight / 2
            let bottomY: CGFloat = h - scalePad - segmentHeight / 2

            // Major marks — labeled
            for db in majorMarks {
                let y = scale.perceptualY(db: Double(db), topCenter: Double(topY), bottomCenter: Double(bottomY))

                if leftSide {
                    // Tick on right edge (near meter)
                    var tick = Path()
                    tick.move(to: CGPoint(x: size.width - 5, y: y))
                    tick.addLine(to: CGPoint(x: size.width - 2, y: y))
                    context.stroke(tick, with: .color(.gray.opacity(0.5)), lineWidth: 0.5)

                    // Label right-aligned (before tick)
                    let label = rangeDB == 48
                        ? (db == 0 ? "0" : "-\(db)")
                        : "\(db)"
                    let text = Text(label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.gray)
                    context.draw(text, at: CGPoint(x: size.width - 7, y: y), anchor: .trailing)
                } else {
                    // Tick on left edge (near meter)
                    var tick = Path()
                    tick.move(to: CGPoint(x: 2, y: y))
                    tick.addLine(to: CGPoint(x: 5, y: y))
                    context.stroke(tick, with: .color(.gray.opacity(0.5)), lineWidth: 0.5)

                    // Label left-aligned (after tick)
                    let label = rangeDB == 48
                        ? (db == 0 ? "0" : "-\(db)")
                        : "\(db)"
                    let text = Text(label)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.gray)
                    context.draw(text, at: CGPoint(x: 7, y: y), anchor: .leading)
                }
            }

            // Minor marks — tick only, no label (perceptual density near 0)
            for db in minorMarks {
                let y = scale.perceptualY(db: Double(db), topCenter: Double(topY), bottomCenter: Double(bottomY))
                if leftSide {
                    var tick = Path()
                    tick.move(to: CGPoint(x: size.width - 3, y: y))
                    tick.addLine(to: CGPoint(x: size.width - 1, y: y))
                    context.stroke(tick, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                } else {
                    var tick = Path()
                    tick.move(to: CGPoint(x: 3, y: y))
                    tick.addLine(to: CGPoint(x: 5, y: y))
                    context.stroke(tick, with: .color(.gray.opacity(0.3)), lineWidth: 0.5)
                }
            }
        }
        .frame(width: 30, height: height + scalePad * 2)
        .offset(y: -scalePad)  // center the padded canvas on the meter
    }

    private var segmentHeight: CGFloat {
        (height - CGFloat(segmentCount - 1) * segmentGap) / CGFloat(segmentCount)
    }

    private func dBForSegment(_ index: Int) -> Double {
        scale.dBForSegment(index)
    }

    private func colorForSegment(_ index: Int) -> Color {
        let db = dBForSegment(index)
        if db >= -1 { return .red }           // Clip / Over
        if db >= -6 { return .orange }         // Hot
        if db >= -12 { return .yellow }        // Warm
        return Color(red: 0.2, green: 0.8, blue: 0.3) // Normal (green)
    }

}
