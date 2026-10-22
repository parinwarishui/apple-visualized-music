//
//  SupermassiveControls.swift
//
//  SuperMassive branch only. A generic "full control" rack for Supermassive:
//  reads every parameter Supermassive itself reports (SupermassiveControl, in
//  SupermassiveReverb.swift) and renders each one without assuming its name
//  or how many there are — a Picker for anything with discrete options (e.g.
//  Mode), a circular knob for anything continuous. That also means it's
//  automatically right regardless of what Supermassive's real display names
//  turn out to be, which SupermassiveReverb.swift is still guessing at.
//
//  NOT YET SEEN RENDERED: built without a working SwiftUI preview or a real
//  device to run it on. Layout (knob size, grid spacing, label truncation) is
//  a best guess and may need adjusting once it's actually on screen.
//

import SwiftUI
import AVFoundation

/// A circular rotary control, dragged vertically (up increases, down
/// decreases) since SwiftUI has no built-in radial drag gesture. `value` is
/// normalized 0...1; callers map to/from a parameter's real range.
struct KnobControl: View {
    let label: String
    @Binding var value: Float

    /// Vertical pixels of drag to cover the whole 0...1 travel. Smaller = more
    /// sensitive. Picked to roughly match the panel's other sliders; untested.
    private let dragTravel: CGFloat = 120

    @State private var dragStartValue: Float?

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.25), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: CGFloat(value))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.none, value: value)
                Circle()
                    .fill(Color.secondary.opacity(0.1))
                    .padding(7)
                // Pointer: 0 at bottom-left (-135°), 1 at bottom-right (+135°),
                // matching the trimmed arc above (a 270° sweep starting at -90°
                // in trim-space, i.e. -135° in on-screen degrees).
                Rectangle()
                    .fill(Color.primary.opacity(0.8))
                    .frame(width: 2, height: 9)
                    .offset(y: -13)
                    .rotationEffect(.degrees(Double(value) * 270 - 135))
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { drag in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil { dragStartValue = value }
                        let delta = Float(-drag.translation.height) / Float(dragTravel)
                        value = min(max(start + delta, 0), 1)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
            // Double-click/tap resets to centre — there's no per-parameter
            // "default" available from the AU, so this is the closest to one.
            .onTapGesture(count: 2) { value = 0.5 }

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 60)
        }
    }
}

/// Every control Supermassive reports, laid out as a grid of knobs (and one
/// Picker per discrete/indexed parameter, e.g. Mode). Shown under the normal
/// Space/Mix controls when Supermassive is active, for hands-on tuning instead
/// of (or alongside) the five hand-picked presets in SupermassiveReverb.swift.
struct SupermassiveRackView: View {
    let controls: [SupermassiveControl]

    private let columns = [GridItem(.adaptive(minimum: 60, maximum: 64), spacing: 10)]

    var body: some View {
        if controls.isEmpty {
            // Shouldn't normally show (callers gate on supermassiveActive),
            // but fails quietly rather than rendering an empty, odd-looking box.
            EmptyView()
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(controls) { control in
                    ControlView(control: control)
                }
            }
        }
    }

    private struct ControlView: View {
        let control: SupermassiveControl

        var body: some View {
            let param = control.param
            if let strings = param.valueStrings, !strings.isEmpty {
                VStack(spacing: 4) {
                    Picker(param.displayName, selection: indexBinding) {
                        ForEach(Array(strings.enumerated()), id: \.offset) { index, name in
                            Text(name).tag(index)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 60)
                    Text(param.displayName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: 60)
                }
            } else {
                KnobControl(label: param.displayName, value: normalizedBinding)
            }
        }

        private var normalizedBinding: Binding<Float> {
            Binding<Float>(
                get: {
                    let param = control.param
                    let range = param.maxValue - param.minValue
                    return range > 0 ? (param.value - param.minValue) / range : 0
                },
                set: { newValue in
                    let param = control.param
                    let range = param.maxValue - param.minValue
                    param.value = param.minValue + min(max(newValue, 0), 1) * range
                }
            )
        }

        private var indexBinding: Binding<Int> {
            Binding<Int>(
                get: { Int(control.param.value.rounded()) },
                set: { control.param.value = Float($0) }
            )
        }
    }
}
