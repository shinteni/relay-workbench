import AppKit
import SwiftUI

/// Which edge or corner of a floating terminal window a resize drag grabs.
enum RelayResizeHandle: CaseIterable {
    case left, right, top, bottom
    case topLeft, topRight, bottomLeft, bottomRight

    var affectsLeft: Bool {
        self == .left || self == .topLeft || self == .bottomLeft
    }

    var affectsRight: Bool {
        self == .right || self == .topRight || self == .bottomRight
    }

    var affectsTop: Bool {
        self == .top || self == .topLeft || self == .topRight
    }

    var affectsBottom: Bool {
        self == .bottom || self == .bottomLeft || self == .bottomRight
    }
}

/// Pure frame math for free-floating terminal windows inside the workspace.
enum RelayWindowGeometry {
    static let minSize = CGSize(width: 320, height: 200)
    /// Reserved band at the top of the workspace. Zero: the header drag is
    /// AppKit-backed (`mouseDownCanMoveWindow = false`), so it keeps working
    /// even inside the main window's transparent titlebar strip.
    static let topInset: CGFloat = 0
    static let margin: CGFloat = 10
    static let tileGap: CGFloat = 10

    /// The area of the workspace that windows may occupy.
    static func canvas(_ size: CGSize) -> CGRect {
        CGRect(
            x: 0, y: topInset,
            width: max(size.width, 0),
            height: max(size.height - topInset, 0)
        )
    }

    /// Shrinks and shifts a frame until it lies inside the canvas.
    static func fitted(_ frame: CGRect, in size: CGSize) -> CGRect {
        let area = canvas(size)
        guard area.width > 0, area.height > 0 else { return frame }
        var fit = frame
        fit.size.width = min(max(fit.width, min(minSize.width, area.width)), area.width)
        fit.size.height = min(max(fit.height, min(minSize.height, area.height)), area.height)
        fit.origin.x = min(max(fit.minX, area.minX), area.maxX - fit.width)
        fit.origin.y = min(max(fit.minY, area.minY), area.maxY - fit.height)
        return fit
    }

    static func moved(
        _ base: CGRect, translation: CGSize, in size: CGSize
    ) -> CGRect {
        fitted(
            CGRect(
                x: base.minX + translation.width,
                y: base.minY + translation.height,
                width: base.width,
                height: base.height
            ),
            in: size
        )
    }

    static func resized(
        _ base: CGRect,
        handle: RelayResizeHandle,
        translation: CGSize,
        in size: CGSize
    ) -> CGRect {
        let area = canvas(size)
        var frame = base
        if handle.affectsLeft {
            let newLeft = min(
                max(base.minX + translation.width, area.minX),
                base.maxX - minSize.width
            )
            frame.origin.x = newLeft
            frame.size.width = base.maxX - newLeft
        }
        if handle.affectsRight {
            let newRight = min(
                max(base.maxX + translation.width, base.minX + minSize.width),
                area.maxX
            )
            frame.size.width = newRight - base.minX
        }
        if handle.affectsTop {
            let newTop = min(
                max(base.minY + translation.height, area.minY),
                base.maxY - minSize.height
            )
            frame.origin.y = newTop
            frame.size.height = base.maxY - newTop
        }
        if handle.affectsBottom {
            let newBottom = min(
                max(base.maxY + translation.height, base.minY + minSize.height),
                area.maxY
            )
            frame.size.height = newBottom - base.minY
        }
        return frame
    }

    /// Staggered default frame for the n-th opened window.
    static func cascadeFrame(serial: Int, in size: CGSize) -> CGRect {
        let area = canvas(size)
        guard area.width >= minSize.width, area.height >= minSize.height else {
            return CGRect(origin: CGPoint(x: 0, y: topInset), size: minSize)
        }
        let width = min(max(area.width * 0.58, 460), area.width - margin * 2)
        let height = min(max(area.height * 0.62, 340), area.height - margin * 2)
        let offset = CGFloat(serial % 6) * 30
        return fitted(
            CGRect(
                x: area.minX + margin + offset,
                y: area.minY + margin + offset,
                width: width,
                height: height
            ),
            in: size
        )
    }

    /// Non-overlapping grid frames for `count` windows (1 full, 2 columns,
    /// 3 one tall + two stacked, 4 a 2×2 grid).
    static func tiled(count: Int, in size: CGSize) -> [CGRect] {
        let area = canvas(size).insetBy(dx: margin, dy: margin)
        guard count > 0, area.width > 0, area.height > 0 else { return [] }

        func hsplit(_ rect: CGRect) -> (CGRect, CGRect) {
            let width = (rect.width - tileGap) / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: width, height: rect.height),
                CGRect(x: rect.minX + width + tileGap, y: rect.minY, width: width, height: rect.height)
            )
        }
        func vsplit(_ rect: CGRect) -> (CGRect, CGRect) {
            let height = (rect.height - tileGap) / 2
            return (
                CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height),
                CGRect(x: rect.minX, y: rect.minY + height + tileGap, width: rect.width, height: height)
            )
        }

        func row(_ rect: CGRect, count: Int) -> [CGRect] {
            guard count > 0 else { return [] }
            let width = (rect.width - tileGap * CGFloat(count - 1)) / CGFloat(count)
            return (0..<count).map { index in
                CGRect(
                    x: rect.minX + CGFloat(index) * (width + tileGap),
                    y: rect.minY, width: width, height: rect.height
                )
            }
        }

        switch count {
        case 1:
            return [area]
        case 2:
            let (left, right) = hsplit(area)
            return [left, right]
        case 3:
            let (left, right) = hsplit(area)
            let (rightTop, rightBottom) = vsplit(right)
            return [left, rightTop, rightBottom]
        case 4:
            let (left, right) = hsplit(area)
            let (leftTop, leftBottom) = vsplit(left)
            let (rightTop, rightBottom) = vsplit(right)
            return [leftTop, rightTop, leftBottom, rightBottom]
        default:
            let (top, bottom) = vsplit(area)
            let topCount = (count + 1) / 2
            return row(top, count: topCount) + row(bottom, count: count - topCount)
        }
    }
}

/// 前回のデスクを構成した CLI ターミナルの復元用データ。
/// メインウィンドウのサイズ変更後も配置を保つため、座標は正規化する。