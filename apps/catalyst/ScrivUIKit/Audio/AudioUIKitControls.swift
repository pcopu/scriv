import UIKit
import ScrivCore

enum AudioUIKitLayout {
    static func separator() -> UIView {
        let view = UIView(); view.backgroundColor = ScrivUIKitTheme.hairline
        view.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        return view
    }
    static func scrollContent(_ content: UIView, in container: UIView, padding: CGFloat = 22) -> UIScrollView {
        let scroll = UIScrollView(); scroll.alwaysBounceVertical = false
        container.addSubview(scroll); scroll.scrivPinEdges(to: container)
        scroll.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -padding),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -2 * padding)
        ])
        return scroll
    }
    static func row(_ views: [UIView], spacing: CGFloat = 12) -> UIStackView {
        let stack = ScrivUIKitTheme.stack(views, axis: .horizontal, spacing: spacing); stack.alignment = .center
        return stack
    }
    static func symbolButton(_ name: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: name), for: .normal); button.tintColor = ScrivUIKitTheme.secondary
        button.accessibilityLabel = label; button.addAction(UIAction { _ in action() }, for: .primaryActionTriggered)
        NSLayoutConstraint.activate([button.widthAnchor.constraint(equalToConstant: 30), button.heightAnchor.constraint(equalToConstant: 30)])
        return button
    }
}

/// Precision text and explicit 100 ms increment/decrement controls. Invalid
/// typed values are retained rather than silently replaced by formatter output.
final class AudioSecondsField: UIView {
    let textField = UITextField()
    private let titleLabel = ScrivUIKitTheme.label("", size: 13)
    private let box = UIView()
    private var maximumMs: Int
    private let minimumMs: Int
    var onChange: ((String) -> Void)?
    var text: String { get { textField.text ?? "" } set { textField.text = newValue } }
    init(title: String?, accessibilityName: String, maximumMs: Int, minimumMs: Int = 0, identifier: String) {
        self.maximumMs = maximumMs; self.minimumMs = minimumMs
        super.init(frame: .zero)
        titleLabel.text = title; titleLabel.isHidden = title == nil
        textField.font = .monospacedDigitSystemFont(ofSize: 14, weight: .regular)
        textField.placeholder = "0.000"; textField.keyboardType = .decimalPad
        textField.accessibilityLabel = accessibilityName + ", seconds"; textField.accessibilityIdentifier = identifier
        textField.autocorrectionType = .no; textField.spellCheckingType = .no
        textField.addTarget(self, action: #selector(edited), for: .editingChanged)
        let up = UIButton(type: .system), down = UIButton(type: .system)
        up.setImage(UIImage(systemName: "chevron.up"), for: .normal); down.setImage(UIImage(systemName: "chevron.down"), for: .normal)
        let config = UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        up.setPreferredSymbolConfiguration(config, forImageIn: .normal); down.setPreferredSymbolConfiguration(config, forImageIn: .normal)
        up.accessibilityLabel = "Increase " + accessibilityName + " by 0.100 seconds"
        down.accessibilityLabel = "Decrease " + accessibilityName + " by 0.100 seconds"
        up.addAction(UIAction { [weak self] _ in self?.step(100) }, for: .primaryActionTriggered)
        down.addAction(UIAction { [weak self] _ in self?.step(-100) }, for: .primaryActionTriggered)
        let steppers = ScrivUIKitTheme.stack([up, down], spacing: 0); steppers.distribution = .fillEqually
        NSLayoutConstraint.activate([steppers.widthAnchor.constraint(equalToConstant: 23), steppers.heightAnchor.constraint(equalToConstant: 32)])
        let entry = AudioUIKitLayout.row([textField, steppers], spacing: 4)
        box.backgroundColor = ScrivUIKitTheme.panel; box.layer.cornerRadius = 7; box.layer.borderWidth = 0.8
        box.addSubview(entry); entry.scrivPinEdges(to: box, insets: .init(top: 2, leading: 10, bottom: 2, trailing: 5))
        let unit = ScrivUIKitTheme.label("s", size: 13, color: ScrivUIKitTheme.secondary)
        unit.setContentHuggingPriority(.required, for: .horizontal)
        let stack = ScrivUIKitTheme.stack([titleLabel, AudioUIKitLayout.row([box, unit], spacing: 8)], spacing: 7)
        addSubview(stack); stack.scrivPinEdges(to: self)
        box.heightAnchor.constraint(equalToConstant: 36).isActive = true
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init") }
    override func layoutSubviews() { super.layoutSubviews(); box.layer.borderColor = ScrivUIKitTheme.hairline.cgColor }
    func setMaximum(_ maximum: Int) { maximumMs = maximum }
    @objc private func edited() { onChange?(text) }
    private func step(_ delta: Int) {
        let current = AudioTimingInput.milliseconds(text, maximum: maximumMs) ?? minimumMs
        text = AudioTimingInput.seconds(min(maximumMs, max(minimumMs, current + delta))); onChange?(text)
    }
}

final class AudioTimingNotice: UIView {
    private let message = ScrivUIKitTheme.label("", size: 12)
    init() {
        super.init(frame: .zero)
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill")); icon.tintColor = .systemOrange
        icon.contentMode = .scaleAspectFit
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 20), icon.heightAnchor.constraint(equalToConstant: 22)])
        let copy = ScrivUIKitTheme.stack([
            ScrivUIKitTheme.label("Timing needs a small fix", size: 13, weight: .semibold), message,
            ScrivUIKitTheme.label("Your changes are still in this editor. Nothing was applied from this draft.", size: 11, color: ScrivUIKitTheme.secondary)
        ], spacing: 5)
        let row = AudioUIKitLayout.row([icon, copy], spacing: 10); row.alignment = .top
        addSubview(row); row.scrivPinEdges(to: self, insets: .init(top: 12, leading: 12, bottom: 12, trailing: 12))
        backgroundColor = UIColor.systemOrange.withAlphaComponent(0.10); layer.cornerRadius = 9; isHidden = true
        accessibilityIdentifier = "audio-timing-validation"
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init") }
    func show(_ text: String?) { message.text = text; isHidden = text == nil }
}

/// Draws measured, decoded PCM peaks only. Zero samples remain a flat baseline.
/// A trim selects source recording time, never scene placement time.
final class MeasuredAudioWaveformView: UIView {
    var peaks: [Float] = [] { didSet { setNeedsDisplay() } }
    var sourceDurationMs = 1 { didSet { setNeedsDisplay() } }
    var trim: ClosedRange<Int>? { didSet { updateAccessibility(); setNeedsDisplay() } }
    var playheadMs: Int? { didSet { setNeedsDisplay() } }
    var playedFraction: Double? { didSet { setNeedsDisplay() } }
    var muted = false { didSet { setNeedsDisplay() } }
    var onTrimChanged: ((ClosedRange<Int>) -> Void)?
    private var draggingStart = true
    private lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private var plot: CGRect { bounds.insetBy(dx: onTrimChanged == nil ? 0 : 12, dy: 10) }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear; isOpaque = false; isAccessibilityElement = true
        accessibilityLabel = "Measured audio waveform"
        drag.maximumNumberOfTouches = 1; addGestureRecognizer(drag)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init") }
    override func layoutSubviews() { super.layoutSubviews(); setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), plot.width > 0 else { return }
        let area = plot, mid = area.midY
        context.setStrokeColor(ScrivUIKitTheme.secondary.withAlphaComponent(0.22).cgColor); context.setLineWidth(0.5)
        context.move(to: CGPoint(x: area.minX, y: mid)); context.addLine(to: CGPoint(x: area.maxX, y: mid)); context.strokePath()
        if let trim {
            let left = x(trim.lowerBound), right = x(trim.upperBound)
            context.setFillColor(ScrivUIKitTheme.accent.withAlphaComponent(0.09).cgColor)
            context.fill(CGRect(x: left, y: area.minY, width: max(1, right - left), height: area.height))
        }
        let step = area.width / CGFloat(max(1, peaks.count))
        context.setLineWidth(min(2, max(0.5, step * 0.65))); context.setLineCap(.round)
        for (index, peak) in peaks.enumerated() where peak.isFinite && peak > 0 {
            let barX = area.minX + (CGFloat(index) + 0.5) * step
            let amplitude = CGFloat(min(1, max(0, peak))) * max(0, area.height / 2 - 1)
            let sourceTime = Double(index) / Double(max(1, peaks.count)) * Double(sourceDurationMs)
            let selected = trim.map { sourceTime >= Double($0.lowerBound) && sourceTime <= Double($0.upperBound) }
                ?? playedFraction.map { Double(index) / Double(max(1, peaks.count)) <= min(1, max(0, $0)) } ?? false
            let color = selected && !muted ? ScrivUIKitTheme.accent : ScrivUIKitTheme.secondary.withAlphaComponent(0.35)
            context.setStrokeColor(color.cgColor); context.move(to: CGPoint(x: barX, y: mid - amplitude))
            context.addLine(to: CGPoint(x: barX, y: mid + amplitude)); context.strokePath()
        }
        if let trim, onTrimChanged != nil {
            for time in [trim.lowerBound, trim.upperBound] {
                let location = x(time)
                context.setFillColor(ScrivUIKitTheme.accent.cgColor)
                context.fill(CGRect(x: location - 1.5, y: area.minY - 2, width: 3, height: area.height + 4))
                UIBezierPath(roundedRect: CGRect(x: location - 4, y: mid - 13, width: 8, height: 26), cornerRadius: 2).fill()
                context.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                context.fill(CGRect(x: location - 0.5, y: mid - 6, width: 1, height: 12))
            }
        }
        if let time = playheadMs, time >= 0, time <= sourceDurationMs { drawAudioPlayhead(context, x: x(time), top: 2, bottom: bounds.maxY - 1) }
    }
    private func x(_ time: Int) -> CGFloat { plot.minX + plot.width * CGFloat(time) / CGFloat(max(1, sourceDurationMs)) }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard let trim, onTrimChanged != nil else { return false }
        let location = gestureRecognizer.location(in: self).x
        draggingStart = abs(location - x(trim.lowerBound)) <= abs(location - x(trim.upperBound))
        return min(abs(location - x(trim.lowerBound)), abs(location - x(trim.upperBound))) <= 22
    }
    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        guard let trim, recognizer.state == .began || recognizer.state == .changed else { return }
        let fraction = min(1, max(0, (recognizer.location(in: self).x - plot.minX) / max(1, plot.width)))
        let time = Int((fraction * CGFloat(sourceDurationMs)).rounded())
        let changed = draggingStart ? min(trim.upperBound - 1, max(0, time))...trim.upperBound : trim.lowerBound...min(sourceDurationMs, max(trim.lowerBound + 1, time))
        onTrimChanged?(changed)
    }
    private func updateAccessibility() {
        guard let trim else { accessibilityValue = peaks.contains(where: { $0 > 0 }) ? "Measured recording peaks" : "Silent recording"; accessibilityCustomActions = nil; return }
        accessibilityValue = "Source in \(AudioTimingInput.seconds(trim.lowerBound)) seconds; duration \(AudioTimingInput.seconds(trim.upperBound - trim.lowerBound)) seconds"
        accessibilityCustomActions = [
            trimAction("Move source in earlier", start: true, delta: -100), trimAction("Move source in later", start: true, delta: 100),
            trimAction("Move source out earlier", start: false, delta: -100), trimAction("Move source out later", start: false, delta: 100)
        ]
    }
    private func trimAction(_ name: String, start: Bool, delta: Int) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: name) { [weak self] _ in
            guard let self, let range = self.trim, let change = self.onTrimChanged else { return false }
            if start { change(min(range.upperBound - 1, max(0, range.lowerBound + delta))...range.upperBound) }
            else { change(range.lowerBound...min(self.sourceDurationMs, max(range.lowerBound + 1, range.upperBound + delta))) }
            return true
        }
    }
}

private func drawAudioPlayhead(_ context: CGContext, x: CGFloat, top: CGFloat, bottom: CGFloat) {
    context.setStrokeColor(ScrivUIKitTheme.accent.cgColor); context.setFillColor(ScrivUIKitTheme.accent.cgColor)
    context.setLineWidth(1); context.move(to: CGPoint(x: x, y: top + 7)); context.addLine(to: CGPoint(x: x, y: bottom)); context.strokePath()
    context.move(to: CGPoint(x: x - 4, y: top)); context.addLine(to: CGPoint(x: x + 4, y: top)); context.addLine(to: CGPoint(x: x, y: top + 7)); context.closePath(); context.fillPath()
}

final class ManualWordTimelineView: UIView {
    var words: [TimedWord] = [] { didSet { setNeedsDisplay() } }
    var selectedID = "" { didSet { setNeedsDisplay() } }
    var durationMs = 1 { didSet { setNeedsDisplay() } }
    var playheadMs: Int? { didSet { setNeedsDisplay() } }
    var onSelect: ((String) -> Void)?
    var onRangeChanged: ((ClosedRange<Int>) -> Void)?
    private var draggingStart = true
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
    private var selected: TimedWord? { words.first { $0.id == selectedID } }
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = false; backgroundColor = .clear
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))))
        pan.maximumNumberOfTouches = 1; addGestureRecognizer(pan)
        accessibilityLabel = "Manual word timing overview"; isAccessibilityElement = true
        accessibilityHint = "Choose a word in the word buttons, then edit its Start and End fields."
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init") }
    override func layoutSubviews() { super.layoutSubviews(); setNeedsDisplay() }
    private func x(_ time: Int) -> CGFloat { 8 + max(1, bounds.width - 16) * CGFloat(time) / CGFloat(max(1, durationMs)) }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let left: CGFloat = 8, right = bounds.width - 8, width = max(1, right - left)
        for word in words {
            let color = word.id == selectedID ? ScrivUIKitTheme.accent.withAlphaComponent(0.23) : ScrivUIKitTheme.secondary.withAlphaComponent(0.13)
            color.setFill()
            UIBezierPath(roundedRect: CGRect(x: x(word.startMs), y: 19, width: max(2, x(word.endMs) - x(word.startMs) - 2), height: 17), cornerRadius: 3).fill()
        }
        context.setStrokeColor(ScrivUIKitTheme.secondary.withAlphaComponent(0.35).cgColor); context.setLineWidth(0.7)
        context.move(to: CGPoint(x: left, y: 45)); context.addLine(to: CGPoint(x: right, y: 45))
        for index in 0...10 {
            let tick = left + CGFloat(index) * width / 10
            context.move(to: CGPoint(x: tick, y: 45)); context.addLine(to: CGPoint(x: tick, y: index.isMultiple(of: 5) ? 54 : 51))
        }
        context.strokePath()
        if let time = playheadMs, time >= 0, time <= durationMs { drawAudioPlayhead(context, x: x(time), top: 5, bottom: 51) }
        if let word = selected {
            context.setFillColor(ScrivUIKitTheme.accent.cgColor)
            for time in [word.startMs, word.endMs] { context.fill(CGRect(x: x(time) - 1.5, y: 16, width: 3, height: 23)) }
            accessibilityValue = "\(word.text): \(AudioTimingInput.seconds(word.startMs)) to \(AudioTimingInput.seconds(word.endMs)) seconds"
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: ScrivUIKitTheme.secondary]
        ("0.0" as NSString).draw(at: CGPoint(x: left, y: 57), withAttributes: attributes)
        let end = NSString(format: "%.1f s", Double(durationMs) / 1000)
        end.draw(at: CGPoint(x: right - end.size(withAttributes: attributes).width, y: 57), withAttributes: attributes)
    }
    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        let location = gesture.location(in: self)
        guard (10...44).contains(location.y) else { return }
        if let word = words.first(where: { location.x >= x($0.startMs) && location.x <= x($0.endMs) }) { onSelect?(word.id) }
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer is UIPanGestureRecognizer else { return super.gestureRecognizerShouldBegin(gestureRecognizer) }
        guard let word = selected else { return false }
        let location = gestureRecognizer.location(in: self).x
        draggingStart = abs(location - x(word.startMs)) <= abs(location - x(word.endMs))
        return min(abs(location - x(word.startMs)), abs(location - x(word.endMs))) <= 18
    }
    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let word = selected, gesture.state == .began || gesture.state == .changed else { return }
        let fraction = min(1, max(0, (gesture.location(in: self).x - 8) / max(1, bounds.width - 16)))
        let time = Int((fraction * CGFloat(durationMs)).rounded())
        if draggingStart { onRangeChanged?(min(word.endMs - 1, max(0, time))...word.endMs) }
        else { onRangeChanged?(word.startMs...min(durationMs, max(word.startMs + 1, time))) }
    }
}
