import SwiftUI

/// Compact inline config panel shown on the overlay when the bubble is tapped.
/// Rendered inside the overlay window so it floats above host sheets alongside the bubble.
struct BubbleConfigPanel: View {

    @ObservedObject var settings: SettingsStore
    @ObservedObject var recorder: RecordingController
    let onToggleRecording: () -> Void
    let onTurnOff: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordButton
            shapeRow

            Toggle("Mirror", isOn: $settings.mirror)
                .font(.subheadline)

            slider(title: "Opacity",
                   value: $settings.opacity,
                   range: 0.2...1.0,
                   display: "\(Int(settings.opacity * 100))%")

            slider(title: "Size",
                   value: Binding(get: { Double(settings.size) },
                                  set: { settings.size = CGFloat($0) }),
                   range: 80...320,
                   display: "\(Int(settings.size))pt")

            slider(title: "Border",
                   value: Binding(get: { Double(settings.borderWidth) },
                                  set: { settings.borderWidth = CGFloat($0) }),
                   range: 0...8,
                   display: "\(Int(settings.borderWidth))pt")

            HStack(spacing: 8) {
                Text("Color")
                    .font(.subheadline)
                    .frame(width: 56, alignment: .leading)
                Slider(value: $settings.borderHue, in: 0...1)
                Circle()
                    .fill(Color(hue: settings.borderHue, saturation: 0.7, brightness: 0.95))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().stroke(.secondary, lineWidth: 0.5))
            }

            turnOffButton

            Button(role: .destructive) { settings.reset() } label: {
                Text("Reset").font(.footnote)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .frame(width: 280)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var header: some View {
        HStack {
            Text("Selfie Overlay").font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
    }

    private var turnOffButton: some View {
        Button(action: onTurnOff) {
            HStack(spacing: 6) {
                Image(systemName: "camera.slash.fill")
                    .font(.system(size: 16))
                Text("Turn Off Camera")
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button(action: onToggleRecording) {
            HStack(spacing: 6) {
                Image(systemName: recorder.isRecording ? "stop.circle.fill" : "record.circle.fill")
                    .font(.system(size: 18))
                Text(recorder.isRecording ? "Stop Recording" : "Start Recording")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                recorder.isRecording ? Color.red : Color.accentColor,
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
        .buttonStyle(.plain)
    }

    private var shapeRow: some View {
        HStack(spacing: 6) {
            ForEach(BubbleShape.allCases, id: \.self) { shape in
                Button {
                    settings.shape = shape
                } label: {
                    Image(systemName: iconName(for: shape))
                        .font(.system(size: 18, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background(
                            settings.shape == shape
                                ? Color.accentColor.opacity(0.2)
                                : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(settings.shape == shape ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(shape.displayName)
            }
        }
    }

    private func iconName(for shape: BubbleShape) -> String {
        switch shape {
        case .circle: return "circle.fill"
        case .roundedRect: return "app.fill"
        case .rect: return "square.fill"
        }
    }

    private func slider(title: String,
                        value: Binding<Double>,
                        range: ClosedRange<Double>,
                        display: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.subheadline)
                .frame(width: 56, alignment: .leading)
            Slider(value: value, in: range)
            Text(display)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }
}
