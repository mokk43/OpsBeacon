import CoreGraphics

public enum DisplayGeometryMath {
    public static func defaultFrame(in visibleFrame: CGRect, size: CGSize = .init(width: 520, height: 360)) -> CGRect {
        CGRect(
            x: visibleFrame.maxX - size.width - 16,
            y: visibleFrame.maxY - size.height - 16,
            width: min(size.width, visibleFrame.width),
            height: min(size.height, visibleFrame.height)
        )
    }

    public static func clamped(_ frame: CGRect, into visibleFrame: CGRect, minimumSize: CGSize = .init(width: 320, height: 180)) -> CGRect {
        let width = min(max(frame.width, minimumSize.width), visibleFrame.width * 0.8)
        let height = min(max(frame.height, minimumSize.height), visibleFrame.height * 0.8)
        let x = min(max(frame.origin.x, visibleFrame.minX), visibleFrame.maxX - width)
        let y = min(max(frame.origin.y, visibleFrame.minY), visibleFrame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height).integral
    }
}
