import UIKit

/// Small transient toast shown in the overlay window. Used to announce
/// short-lived confirmations (e.g. "Recording saved") without stealing
/// focus or blocking host UI. Lives inside `PassthroughWindow`'s root, so
/// taps outside the pill fall through to the host app.
final class ToastView: UIView {

    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterialDark))
    private let iconView = UIImageView()
    private let label = UILabel()

    init(message: String, symbolName: String) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false

        blur.clipsToBounds = true
        blur.layer.cornerRadius = 18
        blur.layer.cornerCurve = .continuous
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)

        iconView.image = UIImage(systemName: symbolName)
        iconView.tintColor = .white
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        label.text = message
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -14),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
