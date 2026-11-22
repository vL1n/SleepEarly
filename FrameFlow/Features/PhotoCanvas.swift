import SwiftUI
import UIKit

/// UIKit supplies anchored pinch zoom, inertial panning and double-tap zoom.
struct PhotoCanvas: UIViewRepresentable {
    let image: CGImage?
    let move: (Int) -> Void
    let detail: (Bool) -> Void

    func makeUIView(context: Context) -> CanvasScrollView { CanvasScrollView() }

    func updateUIView(_ view: CanvasScrollView, context: Context) {
        view.move = move
        view.detail = detail
        view.display(image)
    }
}

final class CanvasScrollView: UIScrollView, UIScrollViewDelegate {
    private let picture = UIImageView()
    private var pagingGestures: [UISwipeGestureRecognizer] = []
    private let connectedNavigation = NSHashTable<UINavigationController>.weakObjects()
    private var lastSize = CGSize.zero
    private var aspect: CGFloat = 0
    private var isInspecting = false
    var move: ((Int) -> Void)?
    var detail: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        delegate = self
        maximumZoomScale = 5
        showsVerticalScrollIndicator = false
        showsHorizontalScrollIndicator = false
        contentInsetAdjustmentBehavior = .never
        backgroundColor = .clear
        picture.contentMode = .scaleAspectFit
        addSubview(picture)
        let tap = UITapGestureRecognizer(target: self, action: #selector(doubleTap(_:)))
        tap.numberOfTapsRequired = 2
        addGestureRecognizer(tap)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipe(_:)))
            swipe.direction = direction
            pagingGestures.append(swipe)
            addGestureRecognizer(swipe)
            panGestureRecognizer.require(toFail: swipe)
        }
        isAccessibilityElement = true
        accessibilityLabel = "照片预览"
        accessibilityHint = "双击切换放大或适应屏幕"
        accessibilityTraits = [.image, .button]
    }

    required init?(coder: NSCoder) { fatalError("Use init()") }

    func display(_ image: CGImage?) {
        if picture.image?.cgImage === image { return }
        picture.image = image.map { UIImage(cgImage: $0) }
        let newAspect = image.map { CGFloat($0.width) / CGFloat($0.height) } ?? 0
        if abs(newAspect - aspect) > 0.008 || aspect == 0 {
            lastSize = .zero
        }
        aspect = newAspect
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if window != nil { coordinateNavigationGestures() }
        let size = bounds.size
        guard size != lastSize, size.width > 0, size.height > 0, aspect > 0 else { return }
        lastSize = size
        setZoomScale(1, animated: false)
        let width = min(size.width, size.height * aspect)
        picture.frame = CGRect(x: 0, y: 0, width: width, height: width / aspect)
        contentSize = picture.frame.size
        centerPicture()
    }

    // A compact split view is hosted inside a navigation controller. Inside the
    // photo, paging wins over full-width back; the screen edge still goes back.
    private func coordinateNavigationGestures() {
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController,
               let navigation = (controller as? UINavigationController) ?? controller.navigationController,
               !connectedNavigation.contains(navigation) {
                for swipe in pagingGestures {
                    if let edgeBack = navigation.interactivePopGestureRecognizer {
                        swipe.require(toFail: edgeBack)
                    }
                    #if compiler(>=6.2)
                    if #available(iOS 26.0, *), let contentBack = navigation.interactiveContentPopGestureRecognizer {
                        contentBack.require(toFail: swipe)
                    }
                    #endif
                }
                connectedNavigation.add(navigation)
            }
            responder = current.next
        }
    }

    private func centerPicture() {
        let x = max(0, (bounds.width - contentSize.width) / 2)
        let y = max(0, (bounds.height - contentSize.height) / 2)
        contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { picture }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerPicture()
        let zoomed = zoomScale > 1.1
        guard zoomed != isInspecting else { return }
        isInspecting = zoomed
        // Rotation can change the fitted scale during a SwiftUI layout pass.
        Task { @MainActor [weak self] in
            guard let self, self.isInspecting == zoomed else { return }
            self.detail?(zoomed)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UISwipeGestureRecognizer { return zoomScale <= 1.01 }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func swipe(_ recognizer: UISwipeGestureRecognizer) {
        guard zoomScale <= 1.01 else { return }
        move?(recognizer.direction == .left ? 1 : -1)
    }

    @objc private func doubleTap(_ recognizer: UITapGestureRecognizer) {
        toggleZoom(at: recognizer.location(in: picture))
    }

    override func accessibilityActivate() -> Bool {
        toggleZoom(at: CGPoint(x: picture.bounds.midX, y: picture.bounds.midY))
        return true
    }

    private func toggleZoom(at point: CGPoint) {
        guard picture.image != nil else { return }
        if zoomScale > 1.01 {
            setZoomScale(1, animated: true)
        } else {
            let w = bounds.width / 2.5
            let h = bounds.height / 2.5
            zoom(to: CGRect(x: point.x - w / 2, y: point.y - h / 2, width: w, height: h), animated: true)
        }
    }
}
