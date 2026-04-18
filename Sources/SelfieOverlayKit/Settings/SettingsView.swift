import SwiftUI

/// Built-in settings UI. Host apps can push/present this themselves, or use
/// `SelfieOverlayKit.shared.presentSettings(from:)`.
public struct SelfieOverlaySettingsView: View {

    @ObservedObject private var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    public init(settings: SettingsStore = SelfieOverlayKit.shared.settings) {
        self.settings = settings
    }

    public var body: some View {
        NavigationView {
            Form {
                Section("Shape") {
                    Picker("Shape", selection: $settings.shape) {
                        ForEach(BubbleShape.allCases, id: \.self) { shape in
                            Text(shape.displayName).tag(shape)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Appearance") {
                    Toggle("Mirror (selfie view)", isOn: $settings.mirror)

                    Toggle("Hide during recording", isOn: $settings.hideDuringRecording)

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Opacity")
                            Spacer()
                            Text(String(format: "%.0f%%", settings.opacity * 100))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.opacity, in: 0.2...1.0)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Size")
                            Spacer()
                            Text("\(Int(settings.size))pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.size) },
                            set: { settings.size = CGFloat($0) }
                        ), in: 80...320)
                    }
                }

                Section("Border") {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Width")
                            Spacer()
                            Text("\(Int(settings.borderWidth))pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { Double(settings.borderWidth) },
                            set: { settings.borderWidth = CGFloat($0) }
                        ), in: 0...8)
                    }

                    VStack(alignment: .leading) {
                        HStack {
                            Text("Color")
                            Spacer()
                            Circle()
                                .fill(Color(hue: settings.borderHue, saturation: 0.7, brightness: 0.95))
                                .frame(width: 22, height: 22)
                                .overlay(Circle().stroke(.secondary, lineWidth: 0.5))
                        }
                        Slider(value: $settings.borderHue, in: 0...1)
                    }
                }

                Section {
                    Button(role: .destructive) { settings.reset() } label: {
                        Text("Reset to defaults")
                    }
                }
            }
            .navigationTitle("Selfie Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
