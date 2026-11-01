#if canImport(UIKit) && (DEBUG || HAPPY_FIXTURES)
import HappyLayout
@testable import HappyUI
import UIKit

/// Live placeholders at several speeds side by side (`-screen avatarSpeeds`):
/// a row per speed, each Settings' 100-point picture beside home's and the
/// switcher's small ones, the same placeholders in every row. `-fps N`
/// draws them at N frames a second; `-speeds 1,1.5,2,3` picks the rows;
/// `-dark` is dark mode.
@MainActor
final class AvatarSpeedHarness {
    private static let large: CGFloat = AgentEditButtonLayout.Metrics.avatar
    private static let small: [CGFloat] = [40, 40, AccountSwitcherLayout.Metrics.picture, AccountSwitcherLayout.Metrics.picture]
    /// One of each effect: plasma large; linear, thermal, topography, radial small.
    private static let largeIndex = 125
    private static let smallIndices = [5, 45, 85, 165]

    init(window: UIWindow, arguments: [String]) {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
        }
        window.overrideUserInterfaceStyle = arguments.contains("-dark") ? .dark : .light
        if let fps = value("-fps").flatMap(Float.init) { AvatarShaderRenderer.framesPerSecond = fps }
        let speeds = value("-speeds").map { $0.split(separator: ",").compactMap { Float($0) } } ?? [1, 1.5, 2, 3]
        LiveAvatars.isEnabled = true
        let root = UIViewController()
        root.view.backgroundColor = UIColor(Palette.background)
        window.rootViewController = root
        window.layoutIfNeeded()
        let width = root.view.bounds.width
        let pitch = Self.large + 28
        let top = window.safeAreaInsets.top + 12

        let heading = UILabel(frame: CGRect(x: 16, y: top, width: width - 32, height: 18))
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.textColor = .label
        heading.text = "\(Int(AvatarShaderRenderer.framesPerSecond)) fps"
        root.view.addSubview(heading)

        for (row, speed) in speeds.enumerated() {
            let y = top + 26 + CGFloat(row) * pitch
            let label = UILabel(frame: CGRect(x: 16, y: y, width: 52, height: Self.large))
            label.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
            label.textColor = .label
            label.text = speed == speed.rounded() ? "\(Int(speed))×" : "\(speed)×"
            root.view.addSubview(label)
            var x: CGFloat = 68
            add(to: root.view, frame: CGRect(x: x, y: y, width: Self.large, height: Self.large), index: Self.largeIndex, speed: speed)
            x += Self.large + 16
            for (side, index) in zip(Self.small, Self.smallIndices) {
                add(to: root.view, frame: CGRect(x: x, y: y + (Self.large - side) / 2, width: side, height: side), index: index, speed: speed)
                x += side + 10
            }
        }
    }

    private func add(to parent: UIView, frame: CGRect, index: Int, speed: Float) {
        let host = UIView(frame: frame)
        host.clipsToBounds = true
        host.layer.cornerRadius = frame.width / 2
        parent.addSubview(host)
        let live = LiveAvatarView(frame: host.bounds)
        host.addSubview(live)
        live.draw(ShaderDrawing(index: index, speed: speed))
    }
}
#endif
