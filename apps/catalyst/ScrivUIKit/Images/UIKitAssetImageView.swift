import UIKit
import ScrivCore

enum UIKitAssetImageLoadPhase: Equatable { case empty, loading, loaded, failed }

/// An asynchronous local-file view. A pending read is never called missing,
/// and a reused cell never displays the previous asset's image or failure.
@MainActor final class UIKitAssetImageView: UIView {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>(); cache.totalCostLimit = 96 * 1024 * 1024; cache.countLimit = 128; return cache
    }()
    private(set) var loadPhase: UIKitAssetImageLoadPhase = .empty
    private let imageView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let symbol = UIImageView(image: UIImage(systemName: "photo"))
    private let retryButton = UIButton(type: .system)
    private let placeholder = UIStackView()
    private var loadTask: Task<Void, Never>?
    private var requestID = UUID()
    private var currentURL: URL?
    private var currentDigest: String?
    private var currentFileStamp = ""
    private(set) var loadedDigest: String?
    private var missingText = "Add an image"
    private var initialized = false
    /// Whether the placeholder icon belongs on screen (missing or unreadable image).
    private var wantsSymbol = true { didSet { applyPlaceholderSize() } }
    /// Avatars are too small for icon plus text: the icon pushed the initial
    /// out of a 44-point circle. Small views show the text alone, centred.
    private var isCompact: Bool { min(bounds.width, bounds.height) > 0 && min(bounds.width, bounds.height) < 72 }
    override func layoutSubviews() { super.layoutSubviews(); applyPlaceholderSize() }
    private func applyPlaceholderSize() {
        let compact = isCompact
        if symbol.isHidden != (!wantsSymbol || compact) { symbol.isHidden = !wantsSymbol || compact }
        // An initial fills the avatar; longer placeholder text keeps the small size.
        let initial = compact && (message.text ?? "").count <= 2
        let font: UIFont = initial ? .systemFont(ofSize: max(11, min(bounds.width, bounds.height) * 0.4), weight: .semibold) : .systemFont(ofSize: compact ? 11 : 12)
        if message.font != font { message.font = font }
        placeholder.spacing = compact ? 0 : 8
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = ScrivUIKitTheme.inset
        layer.cornerRadius = 12; clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.clipsToBounds = true; addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor), imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor), imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        placeholder.axis = .vertical; placeholder.alignment = .center; placeholder.spacing = 8
        placeholder.translatesAutoresizingMaskIntoConstraints = false; addSubview(placeholder)
        symbol.tintColor = .secondaryLabel; symbol.contentMode = .scaleAspectFit
        symbol.widthAnchor.constraint(equalToConstant: 32).isActive = true; symbol.heightAnchor.constraint(equalToConstant: 32).isActive = true
        message.font = .systemFont(ofSize: 12); message.textColor = .secondaryLabel; message.numberOfLines = 0; message.textAlignment = .center
        retryButton.setTitle("Retry", for: .normal)
        retryButton.addAction(UIAction { [weak self] _ in self?.startLoad() }, for: .touchUpInside)
        [symbol, spinner, message, retryButton].forEach(placeholder.addArrangedSubview)
        // Unconfigured is an empty placeholder: Retry belongs only to a failed load.
        retryButton.isHidden = true; spinner.isHidden = true
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12), placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
        imageView.isAccessibilityElement = true; imageView.accessibilityTraits = .image
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit { loadTask?.cancel() }

    func configure(url: URL?, title: String, fill: Bool = true, missingText: String = "Add an image", expectedDigest: String? = nil) {
        imageView.accessibilityLabel = title
        imageView.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        self.missingText = missingText
        let values = try? url?.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = "\(values?.contentModificationDate?.timeIntervalSince1970 ?? 0)|\(values?.fileSize ?? 0)"
        guard !initialized || url != currentURL || expectedDigest != currentDigest || stamp != currentFileStamp else { if url == nil { message.text = missingText; applyPlaceholderSize() }; return }
        initialized = true; currentURL = url; currentDigest = expectedDigest; currentFileStamp = stamp; startLoad()
    }
    private func startLoad() {
        loadTask?.cancel(); requestID = UUID()
        loadedDigest = nil; imageView.image = nil; imageView.isHidden = true; placeholder.isHidden = false; retryButton.isHidden = true
        guard let url = currentURL else {
            loadPhase = .empty
            spinner.stopAnimating(); spinner.isHidden = true; message.text = missingText; wantsSymbol = true; accessibilityValue = missingText
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        // Explicit intermediates avoid an exponential overloaded + expression
        // in the Catalyst type checker. Keep the exact same cache identity.
        let cachePath: String = url.absoluteString
        let cacheDigest: String = currentDigest ?? "unverified"
        let modifiedAt: Double = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let byteCount: Int = values?.fileSize ?? 0
        let cacheParts: [String] = [cachePath, cacheDigest, String(modifiedAt), String(byteCount)]
        let key: NSString = cacheParts.joined(separator: "|") as NSString
        if let cached = Self.cache.object(forKey: key) {
            loadPhase = .loaded; loadedDigest = currentDigest; imageView.image = cached; imageView.isHidden = false; placeholder.isHidden = true; spinner.stopAnimating(); accessibilityValue = nil; return
        }
        loadPhase = .loading
        spinner.isHidden = false; spinner.startAnimating(); wantsSymbol = false
        message.text = "Loading image…"; accessibilityValue = "Loading image"
        let request = requestID, expected = currentDigest
        loadTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { () -> Data? in
                guard url.isFileURL, let bytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                      expected == nil || ScrivDigest.sha256(bytes) == expected else { return nil }
                return bytes
            }.value
            guard !Task.isCancelled, let self, self.requestID == request, self.currentURL == url else { return }
            self.spinner.stopAnimating(); self.spinner.isHidden = true
            if let data, let image = UIImage(data: data) {
                self.loadPhase = .loaded; self.loadedDigest = expected
                Self.cache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count)
                self.imageView.image = image; self.imageView.isHidden = false; self.placeholder.isHidden = true; self.accessibilityValue = nil
            } else {
                self.loadPhase = .failed
                self.wantsSymbol = true; self.message.text = "Image could not be read on this Mac"; self.retryButton.isHidden = false
                self.accessibilityValue = "Image unavailable. Retry loading."
            }
        }
    }
}
