import UIKit

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
    private var missingText = "Add an image"
    private var initialized = false

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
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12), placeholder.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12)
        ])
        imageView.isAccessibilityElement = true; imageView.accessibilityTraits = .image
    }
    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }
    deinit { loadTask?.cancel() }

    func configure(url: URL?, title: String, fill: Bool = true, missingText: String = "Add an image") {
        imageView.accessibilityLabel = title
        imageView.contentMode = fill ? .scaleAspectFill : .scaleAspectFit
        self.missingText = missingText
        guard !initialized || url != currentURL else { if url == nil { message.text = missingText }; return }
        initialized = true; currentURL = url; startLoad()
    }
    private func startLoad() {
        loadTask?.cancel(); requestID = UUID()
        imageView.image = nil; imageView.isHidden = true; placeholder.isHidden = false; retryButton.isHidden = true
        guard let url = currentURL else {
            loadPhase = .empty
            spinner.stopAnimating(); spinner.isHidden = true; symbol.isHidden = false; message.text = missingText; accessibilityValue = missingText
            return
        }
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let key = (url.absoluteString + "|" + String(values?.contentModificationDate?.timeIntervalSince1970 ?? 0) + "|" + String(values?.fileSize ?? 0)) as NSString
        if let cached = Self.cache.object(forKey: key) {
            loadPhase = .loaded; imageView.image = cached; imageView.isHidden = false; placeholder.isHidden = true; spinner.stopAnimating(); return
        }
        loadPhase = .loading
        spinner.isHidden = false; spinner.startAnimating(); symbol.isHidden = true
        message.text = "Loading image…"; accessibilityValue = "Loading image"
        let request = requestID
        loadTask = Task { [weak self] in
            let data = await Task.detached(priority: .utility) { url.isFileURL ? try? Data(contentsOf: url, options: .mappedIfSafe) : nil }.value
            guard !Task.isCancelled, let self, self.requestID == request, self.currentURL == url else { return }
            self.spinner.stopAnimating(); self.spinner.isHidden = true
            if let data, let image = UIImage(data: data) {
                self.loadPhase = .loaded
                Self.cache.setObject(image, forKey: key, cost: image.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count)
                self.imageView.image = image; self.imageView.isHidden = false; self.placeholder.isHidden = true; self.accessibilityValue = nil
            } else {
                self.loadPhase = .failed
                self.symbol.isHidden = false; self.message.text = "Image could not be read on this Mac"; self.retryButton.isHidden = false
                self.accessibilityValue = "Image unavailable. Retry loading."
            }
        }
    }
}
