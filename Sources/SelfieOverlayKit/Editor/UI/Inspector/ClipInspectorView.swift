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

    // MARK: - Close

    let closeButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        b.tintColor = .tertiaryLabel
        b.accessibilityLabel = "Close inspector"
        b.accessibilityIdentifier = "inspector.close"
        return b
    }()

    // MARK: - Delete

    let deleteButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "trash"), for: .normal)
        b.tintColor = .systemRed
        b.accessibilityLabel = "Delete clip"
        b.accessibilityIdentifier = "inspector.delete"
        return b
    }()

    /// Fires when the trash button is tapped. The editor applies
    /// `Timeline.removing(clipID:)` through `EditStore.apply` so the
    /// deletion is one undoable step.
    var onDelete: (() -> Void)?

    // MARK: - Duplicate

    let duplicateButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "plus.square.on.square"), for: .normal)
        b.accessibilityLabel = "Duplicate clip"
        b.accessibilityIdentifier = "inspector.duplicate"
        return b
    }()

    /// Fires when duplicate is tapped. The editor routes this through
    /// `Timeline.duplicating(clipID:)` and `EditStore.apply` so the
    /// duplicate is one undoable step.
    var onDuplicate: (() -> Void)?

    var onClose: (() -> Void)?

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

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.addTarget(self, action: #selector(didTapClose), for: .touchUpInside)
        addSubview(closeButton)

        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        deleteButton.addTarget(self, action: #selector(didTapDelete), for: .touchUpInside)
        addSubview(deleteButton)

        duplicateButton.translatesAutoresizingMaskIntoConstraints = false
        duplicateButton.addTarget(self, action: #selector(didTapDuplicate), for: .touchUpInside)
        addSubview(duplicateButton)

        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            deleteButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            deleteButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            deleteButton.widthAnchor.constraint(equalToConstant: 28),
            deleteButton.heightAnchor.constraint(equalToConstant: 28),

            duplicateButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            duplicateButton.trailingAnchor.constraint(equalTo: deleteButton.leadingAnchor, constant: -8),
            duplicateButton.widthAnchor.constraint(equalToConstant: 28),
            duplicateButton.heightAnchor.constraint(equalToConstant: 28),

            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            // Leave room for the close / delete / duplicate buttons so slider
            // value labels ("1.00×", "100%") don't slide under them.
            stack.trailingAnchor.constraint(equalTo: duplicateButton.leadingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])

        speedSlider.addTarget(self, action: #selector(speedSliderChanged), for: .valueChanged)
        speedSlider.addTarget(self, action: #selector(speedSliderReleased), for: [.touchUpInside, .touchUpOutside])
        volumeSlider.addTarget(self, action: #selector(volumeSliderChanged), for: .valueChanged)
        volumeSlider.addTarget(self, action: #selector(volumeSliderReleased), for: [.touchUpInside, .touchUpOutside])
    }

    @objc private func didTapClose() {
        onClose?()
    }

    @objc private func didTapDelete() {
        onDelete?()
    }

    @objc private func didTapDuplicate() {
        onDuplicate?()
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
