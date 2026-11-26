import CoreGraphics

/// Menu bar geometry decisions, in Cocoa screen coordinates (origin at the bottom left of the
/// primary display) unless a name says otherwise.
public enum MenuBarGeometry {
    /// A menu hanging from a menu bar has its top edge at, or a few points below, the bar's
    /// bottom edge. Context menus elsewhere on screen do not count.
    public static let menuGap: CGFloat = 12

    /// How far into a menu bar a menu's top edge may reach. Measured on macOS 27: a status
    /// item's menu hangs 1 point below the bar.
    public static let menuOverlap: CGFloat = 2

    /// The menus among `menus` that hang from one of `menuBars`. A window whose top reaches
    /// into a menu bar covers it rather than hanging from it: an overlay some utilities keep
    /// on screen at the menu level, invisible and click-through, which is never a menu.
    public static func menuBarMenus(_ menus: [CGRect], menuBars: [CGRect]) -> [CGRect] {
        menus.filter { menu in
            menuBars.contains { bar in
                menu.maxY >= bar.minY - menuGap && menu.maxY <= bar.minY + menuOverlap
                    && menu.maxX > bar.minX && menu.minX < bar.maxX
            }
        }
    }

    /// Whether `window` reaches into one of `menuBars`. What a menu bar item opens (a menu,
    /// a popover, a panel) hangs below the bar; a window that covers it is something else,
    /// such as a full-screen overlay.
    public static func coversMenuBar(_ window: CGRect, menuBars: [CGRect]) -> Bool {
        menuBars.contains { bar in
            window.maxY > bar.minY + menuOverlap && window.minY < bar.maxY
                && window.maxX > bar.minX && window.minX < bar.maxX
        }
    }

    /// Whether a click at `point` is outside every menu bar, every menu hanging from one,
    /// and every rectangle in `keep` (the drawer, say).
    public static func isOutside(_ point: CGPoint, menuBars: [CGRect], menus: [CGRect], keep: [CGRect] = []) -> Bool {
        !menuBars.contains { $0.contains(point) }
            && !menuBarMenus(menus, menuBars: menuBars).contains { $0.contains(point) }
            && !keep.contains { $0.contains(point) }
    }

    /// Where an item dropped at `x` goes among `frames` (the other items in its menu bar,
    /// sorted left to right): the index of the first item whose centre is right of `x`.
    public static func insertionIndex(at x: CGFloat, among frames: [CGRect]) -> Int {
        frames.firstIndex { $0.midX > x } ?? frames.count
    }

    /// Origin of a drawer of `size` hanging under `dot`: centred on it, `gap` below the menu
    /// bar, and kept `inset` inside `screen`.
    public static func drawerOrigin(size: CGSize, under dot: CGRect, in screen: CGRect, gap: CGFloat = 6, inset: CGFloat = 8) -> CGPoint {
        let minX = screen.minX + inset
        let maxX = screen.maxX - inset - size.width
        let x = min(max(dot.midX - size.width / 2, minX), max(minX, maxX))
        return CGPoint(x: x.rounded(), y: (dot.minY - gap - size.height).rounded())
    }
}
