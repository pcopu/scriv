import UIKit
import ScrivCore

private final class DirectionHandleButton: UIButton {
    var adjust: ((Int) -> Void)?
    override func accessibilityIncrement() { adjust?(100) }
    override func accessibilityDecrement() { adjust?(-100) }
}

/// Spatial coverage rails never change an entry's owned duration. Zero-second
/// notes occupy layout space without silently advancing the editorial clock.
@MainActor
final class ScriptDirectionRails: UIView {
    private let store: WorkspaceStore
    private var entries: [ScriptEntry] = []
    private var frames: [String: CGRect] = [:]
    private var handles: [String: (UIButton, DirectionHandleButton)] = [:]
    private var drag: (id: String, originalY: CGFloat, currentY: CGFloat, navigation: Int, entry: ScriptEntry)?
    private let railX: CGFloat = 112
    init(store: WorkspaceStore) { self.store = store; super.init(frame: .zero); backgroundColor = .clear; isOpaque = false }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func update(entries: [ScriptEntry], frames: [String: CGRect]) {
        self.entries = entries; self.frames = frames
        let ids = Set(entries.filter { $0.kind == .direction }.map(\.id))
        for id in Array(handles.keys) where !ids.contains(id) { let pair = handles.removeValue(forKey: id); pair?.0.removeFromSuperview(); pair?.1.removeFromSuperview() }
        for entry in entries where entry.kind == .direction {
            if handles[entry.id] == nil {
                let start = UIButton(type: .system), end = DirectionHandleButton(type: .system)
                start.addAction(UIAction { [weak self] _ in self?.store.selectEntry(entry.id) }, for: .touchUpInside)
                end.addAction(UIAction { [weak self] _ in self?.store.selectEntry(entry.id) }, for: .touchUpInside)
                let pan = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:))); end.addGestureRecognizer(pan); end.accessibilityIdentifier = entry.id
                end.adjust = { [weak self] delta in
                    guard let self, self.store.lockedByOther(entry.id) == nil, let current = self.store.project.entries.first(where: { $0.id == entry.id }) else { return }
                    self.store.setCoverage(current.id, endMs: self.store.project.startMs(of: current.id) + max(current.ownedDurationMs, current.coverageDurationMs + delta))
                }
                end.accessibilityTraits = [.adjustable]
                addSubview(start); addSubview(end); handles[entry.id] = (start, end)
            }
        }
        setNeedsLayout(); setNeedsDisplay()
    }
    private var geometry: [ScriptRailRow] {
        entries.compactMap { entry in
            guard let frame = frames[entry.id] else { return nil }
            return ScriptRailRow(startMs: store.project.startMs(of: entry.id), durationMs: entry.ownedDurationMs, anchorY: Double(frame.minY + 26), bottomY: Double(frame.maxY + 23))
        }
    }
    private func y(_ time: Int) -> CGFloat { CGFloat(PresentationGeometry.railPosition(at: time, rows: geometry)) }
    private func endpoint(_ entry: ScriptEntry) -> CGFloat {
        max((frames[entry.id]?.minY ?? 0) + 38, drag?.id == entry.id ? drag!.currentY : y(store.project.startMs(of: entry.id) + entry.coverageDurationMs))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        for entry in entries where entry.kind == .direction {
            guard let row = frames[entry.id], let pair = handles[entry.id] else { continue }
            pair.0.frame = CGRect(x: railX - 12, y: row.minY + 14, width: 24, height: 24)
            pair.1.frame = CGRect(x: railX - 15, y: endpoint(entry) - 15, width: 30, height: 30)
            let color = ScrivUIKitTheme.color(entry.color)
            for button in [pair.0, pair.1] {
                button.setImage(UIImage(systemName: "circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: store.selectedEntryID == entry.id ? 13 : 10)), for: .normal)
                button.tintColor = color
            }
            pair.0.accessibilityLabel = "Select direction: " + entry.text
            pair.1.accessibilityLabel = "Coverage end for " + entry.text
            pair.1.accessibilityValue = ScrivFormat.time(store.project.startMs(of: entry.id) + entry.coverageDurationMs)
            pair.1.isEnabled = store.lockedByOther(entry.id) == nil
            let overlap = entries.filter { candidate in
                guard candidate.kind == .direction, let frame = frames[candidate.id] else { return false }
                return endpoint(entry) >= frame.minY + 12 && endpoint(entry) <= endpoint(candidate) + 14
            }
            pair.1.menu = UIMenu(title: "Overlapping directions", children: overlap.map { candidate in
                UIAction(title: candidate.text, state: candidate.id == store.selectedEntryID ? .on : .off) { [weak self] _ in self?.store.selectEntry(candidate.id) }
            })
            if store.selectedEntryID == entry.id { bringSubviewToFront(pair.0); bringSubviewToFront(pair.1) }
        }
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let directions = entries.filter { $0.kind == .direction }
        for (index, entry) in directions.enumerated() {
            guard let frame = frames[entry.id] else { continue }
            let top = frame.minY + 26, bottom = endpoint(entry), color = ScrivUIKitTheme.color(entry.color)
            context.saveGState(); context.setStrokeColor(color.cgColor); context.setLineWidth(store.selectedEntryID == entry.id ? 4 : 3)
            context.setLineDash(phase: CGFloat(index * 7), lengths: [7, CGFloat(max(1, directions.count - 1) * 7)])
            context.move(to: CGPoint(x: railX, y: top + 9)); context.addLine(to: CGPoint(x: railX, y: bottom)); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
            context.setLineWidth(2.5); context.move(to: CGPoint(x: railX, y: top + 9)); context.addQuadCurve(to: CGPoint(x: railX + 18, y: top), control: CGPoint(x: railX, y: top)); context.addLine(to: CGPoint(x: 164, y: top)); context.strokePath()
            context.setFillColor(color.cgColor); context.move(to: CGPoint(x: 168, y: top)); context.addLine(to: CGPoint(x: 159, y: top - 5)); context.addLine(to: CGPoint(x: 159, y: top + 5)); context.closePath(); context.fillPath(); context.restoreGState()
        }
    }
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool { subviews.contains { !$0.isHidden && $0.frame.insetBy(dx: -3, dy: -3).contains(point) } }
    @objc private func dragged(_ gesture: UIPanGestureRecognizer) {
        guard let button = gesture.view as? UIButton, let id = button.accessibilityIdentifier, let entry = entries.first(where: { $0.id == id }), store.lockedByOther(id) == nil else { return }
        switch gesture.state {
        case .began:
            store.selectEntry(id); drag = (id, endpoint(entry), endpoint(entry), store.navigationContext, entry)
        case .changed:
            guard let old = drag else { return }
            let minimum = max((frames[id]?.minY ?? 0) + 38, y(store.project.startMs(of: id) + entry.ownedDurationMs))
            drag?.currentY = max(minimum, old.originalY + gesture.translation(in: self).y); setNeedsLayout(); setNeedsDisplay()
        case .ended:
            guard let old = drag else { return }; drag = nil
            if old.navigation == store.navigationContext, store.project.entries.first(where: { $0.id == id }) == old.entry, abs(old.currentY - old.originalY) >= 1 {
                let end = max(store.project.startMs(of: id) + entry.ownedDurationMs, PresentationGeometry.railTime(at: Double(old.currentY), rows: geometry))
                store.setCoverage(id, endMs: end)
            }
            setNeedsLayout(); setNeedsDisplay()
        case .cancelled, .failed: drag = nil; setNeedsLayout(); setNeedsDisplay()
        default: break
        }
    }
}
