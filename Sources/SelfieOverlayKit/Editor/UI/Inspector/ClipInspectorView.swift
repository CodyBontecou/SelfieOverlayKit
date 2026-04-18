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

        let title = UILabel()
        title.text = "Speed"
        title.font = .systemFont(ofSize: 13, weight: .semibold)

        let labelRow = UIStackView(arrangedSubviews: [title, speedValueLabel])
        labelRow.axis = .horizontal
        labelRow.spacing = 8
        labelRow.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [labelRow, speedSlider])
        stack.axis = .vertical
        stack.spacing = 4
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
    }

    // MARK: - Public API

    /// Push a clip into the inspector so the controls reflect its current state.
    func configure(with clip: Clip) {
        speedSlider.value = Float(log2(clip.speed))
        speedValueLabel.text = Self.formatSpeed(clip.speed)
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
