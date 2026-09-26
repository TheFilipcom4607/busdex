import CoreGraphics

public enum Viewfinder {
    /// Where `frame` (a rect in a view that shows an image aspect-filled) falls in that image,
    /// normalised to 0…1 with a top-left origin and clipped to the image. Nil when the view,
    /// the image or the overlap is empty.
    public static func region(of frame: CGRect, in viewSize: CGSize, imageSize: CGSize) -> CGRect? {
        guard viewSize.width > 0, viewSize.height > 0, imageSize.width > 0, imageSize.height > 0 else { return nil }
        let scale = max(viewSize.width / imageSize.width, viewSize.height / imageSize.height)
        let offX = (viewSize.width - imageSize.width * scale) / 2
        let offY = (viewSize.height - imageSize.height * scale) / 2
        let r = CGRect(x: (frame.minX - offX) / scale / imageSize.width,
                       y: (frame.minY - offY) / scale / imageSize.height,
                       width: frame.width / scale / imageSize.width,
                       height: frame.height / scale / imageSize.height)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return r.isNull || r.isEmpty ? nil : r
    }
}
