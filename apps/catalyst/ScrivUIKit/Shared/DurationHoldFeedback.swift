import UIKit

/// Hold feedback is separate from the number. Digits never crossfade; the
/// 180 ms progress ring and lock pulse explain when a drag has been captured.
@MainActor final class DurationHoldFeedback: NSObject {
    private weak var button: UIButton?
    private let ring = CAShapeLayer()
    private let lock = UIImageView(image: UIImage(systemName: "lock.fill"))
    private(set) var isLocked = false
    init(button: UIButton) {
        self.button = button; super.init()
        ring.fillColor = UIColor.clear.cgColor; ring.strokeColor = ScrivUIKitTheme.accent.cgColor
        ring.lineWidth = 2; ring.strokeEnd = 0; button.layer.addSublayer(ring)
        lock.tintColor = .white; lock.backgroundColor = ScrivUIKitTheme.accent; lock.layer.cornerRadius = 8
        lock.contentMode = .center; lock.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        lock.isHidden = true; lock.isUserInteractionEnabled = false; button.addSubview(lock)
        button.addTarget(self, action: #selector(beginHold), for: .touchDown)
        button.addTarget(self, action: #selector(endHold), for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        if #available(iOS 15.0, *) { button.changesSelectionAsPrimaryAction = false }
    }
    @objc private func beginHold() {
        guard let button, !isLocked else { return }
        ring.frame = button.bounds; ring.path = UIBezierPath(roundedRect: button.bounds.insetBy(dx: 1, dy: 1), cornerRadius: button.layer.cornerRadius).cgPath
        ring.strokeEnd = 1
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let progress = CABasicAnimation(keyPath: "strokeEnd"); progress.fromValue = 0; progress.toValue = 1; progress.duration = 0.18
        ring.add(progress, forKey: "hold-progress")
    }
    @objc private func endHold() { if !isLocked { reset() } }
    func lockIn() {
        guard let button else { return }; isLocked = true
        ring.frame = button.bounds; ring.path = UIBezierPath(roundedRect: button.bounds.insetBy(dx: 1, dy: 1), cornerRadius: button.layer.cornerRadius).cgPath
        ring.removeAllAnimations(); ring.strokeEnd = 1
        lock.frame = CGRect(x: button.bounds.maxX - 11, y: -5, width: 16, height: 16); lock.isHidden = false
        button.accessibilityValue = "Duration drag locked"
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale"); pulse.values = [1, 1.04, 1]; pulse.keyTimes = [0, 0.45, 1]; pulse.duration = 0.16
        button.layer.add(pulse, forKey: "duration-lock-pulse")
    }
    func reset() {
        isLocked = false; ring.removeAllAnimations(); ring.strokeEnd = 0; lock.isHidden = true
        button?.layer.removeAnimation(forKey: "duration-lock-pulse")
    }
    static func tick(_ button: UIButton?, title: String, update: ((UIButton) -> Void)? = nil) {
        guard let button else { return }
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if var configuration = button.configuration { configuration.title = title; button.configuration = configuration }
            else { button.setTitle(title, for: .normal) }
            update?(button); button.layoutIfNeeded(); button.titleLabel?.layer.removeAllAnimations()
            CATransaction.commit()
        }
    }
}
