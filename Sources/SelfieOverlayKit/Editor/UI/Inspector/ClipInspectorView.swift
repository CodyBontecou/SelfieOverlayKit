import UIKit

/// Bottom-anchored inspector panel. Appears when a clip is selected and
/// exposes per-clip controls. Currently hosts the T12 speed slider; T13
/// will add a volume slider alongside.
final class ClipInspectorView: UIView {

    // MARK: - Speed slider

    static let minSpeed: Double = 0.25
    static let maxSpeed: Double = 4.0

    let speedSlider: UISlider = {
        let s = UISlider()
        s.minimumValue = -2   // log2(0.25)
        s.maximumValue = 2    // log2(4)
        s.value = 0
        s.accessibilityIdentifier = "inspector.speed.slider"
        return s
    }()

    let speedValueLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.text = "1.00×"
        return l
    }()

    // MARK: - Volume slider

    let volumeSlider: UISlider = {
        let s = UISlider()
        s.minimumValue = Float(Timeline.volumeRange.lowerBound)
        s.maximumValue = Float(Timeline.volumeRange.upperBound)
        s.value = 1.0
        s.accessibilityIdentifier = "inspector.volume.slider"
        return s
    }()

    let volumeValueLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        l.textColor = .secondaryLabel
        l.textAlignment = .right
        l.text = "100%"
        return l
    }()

    /// Only present for audio clips — the volume row is hidden when a video
    /// clip is selected (per T13 scope, v1 attaches volume only to audio).
    let volumeRow = UIStackView()

    var onVolumeCommit: ((Float) -> Void)?

    /// Fires while the slider is being dragged (for live label updates).
    var onSpeedChanging: ((Double) -> Void)?

    /// Fires on slider release with the final speed — the inspector user
    /// applies this via `EditStore.apply` so the mutation is one undo step.
    var onSpeedCommit: ((Double) -> Void)?

    // MARK: - Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    private func setup() {
        backgroundColor = .secondarySystemBackground
        layer.cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false

        let speedTitle = UILabel()
        speedTitle.text = "Speed"
        speedTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let speedLabelRow = UIStackView(arrangedSubviews: [speedTitle, speedValueLabel])
        speedLabelRow.axis = .horizontal
        speedLabelRow.spacing = 8
        speedLabelRow.distribution = .fill
        let speedRow = UIStackView(arrangedSubviews: [speedLabelRow, speedSlider])
        speedRow.axis = .vertical
        speedRow.spacing = 4

        let volumeTitle = UILabel()
        volumeTitle.text = "Volume"
        volumeTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let volumeLabelRow = UIStackView(arrangedSubviews: [volumeTitle, volumeValueLabel])
        volumeLabelRow.axis = .horizontal
        volumeLabelRow.spacing = 8
        volumeLabelRow.distribution = .fill
        volumeRow.axis = .vertical
        volumeRow.spacing = 4
        volumeRow.addArrangedSubview(volumeLabelRow)
        volumeRow.addArrangedSubview(volumeSlider)
        volumeRow.isHidden = true

        let stack = UIStackView(arrangedSubviews: [speedRow, volumeRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        speedSlider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)
        speedSlider.addTarget(self, action: #selector(speedSliderReleased), for: [.touchUpInside, .touchUpOutside])
        volumeSlider.addTarget(self, action: #selector(volumeSliderChanged), for: .valueChanged)
        volumeSlider.addTarget(self, action: #selector(volumeSliderReleased), for: [.touchUpInside, .touchUpOutside])
    }

    // MARK: - Public API

    /// Push a clip into the inspector so the controls reflect its current state.
    /// The volume slider appears only for audio clips; T13 scope keeps volume
    /// attached to audio tracks in v1.
    func configure(with clip: Clip, trackKind: Track.Kind) {
        speedSlider.value = Float(log2(clip.speed))
        speedValueLabel.text = Self.formatSpeed(clip.speed)

        volumeRow.isHidden = trackKind != .audio
        volumeSlider.value = clip.volume
        volumeValueLabel.text = Self.formatVolume(clip.volume)
    }

    // MARK: - Events

    @objc private func speedSliderChanged() {
        let speed = Self.speedFromSlider(speedSlider.value)
        speedValueLabel.text = Self.formatSpeed(speed)
        onSpeedChanging?(speed)
    }

    @objc private func speedSliderReleased() {
        let speed = Self.speedFromSlider(speedSlider.value)
        onSpeedCommit?(speed)
    }

    @objc private func volumeSliderChanged() {
        volumeValueLabel.text = Self.formatVolume(volumeSlider.value)
    }

    @objc private func volumeSliderReleased() {
        onVolumeCommit?(volumeSlider.value)
    }

    static func formatVolume(_ value: Float) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    // MARK: - Math helpers (exposed for tests)

    static func speedFromSlider(_ value: Float) -> Double {
        pow(2, Double(value))
    }

    static func sliderFromSpeed(_ speed: Double) -> Float {
        Float(log2(max(0.001, speed)))
    }

    static func formatSpeed(_ speed: Double) -> String {
        String(format: "%.2f×", speed)
    }
}
