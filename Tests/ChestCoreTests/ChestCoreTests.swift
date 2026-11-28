import CoreGraphics
import XCTest
@testable import ChestCore

final class AllowListTests: XCTestCase {
    private func key(_ id: String) -> [String: Any] { ["bundle": ["_0": id]] }

    private func list() -> [Any] {
        [
            key("com.example.a"),
            ["isAllowed": true, "location": key("com.example.a"), "menuItemLocations": [key("com.example.a")]],
            key("com.example.b"),
            ["isAllowed": false, "location": key("com.example.b"),
             "menuItemLocations": [["adhocBinary": ["_0": ["relative": "file:///tmp/B.app/Contents/MacOS/B"]]]]],
        ]
    }

    func testReadsEntries() {
        XCTAssertEqual(AllowList.entries(in: list()), [
            .init(bundleID: "com.example.a", isAllowed: true, itemBundleIDs: ["com.example.a"]),
            .init(bundleID: "com.example.b", isAllowed: false),
        ])
    }

    /// Measured on macOS 27: a helper inside an app's bundle that draws the item gets an
    /// entry keyed by the outer app, listing the helper only as an item location.
    private func helperList() -> [Any] {
        list() + [
            key("com.example.c"),
            ["isAllowed": true, "location": key("com.example.c"), "menuItemLocations": [key("com.example.c.helper")]],
        ]
    }

    func testFindsTheEntryOfAHelperByItsItemLocation() {
        XCTAssertEqual(AllowList.entry(for: "com.example.c.helper", in: helperList())?.bundleID, "com.example.c")
        XCTAssertEqual(AllowList.entry(for: "com.example.c", in: helperList())?.bundleID, "com.example.c")
        XCTAssertEqual(AllowList.entry(for: "com.example.a", in: helperList())?.bundleID, "com.example.a")
        XCTAssertNil(AllowList.entry(for: "com.example.new", in: helperList()))
    }

    func testSwitchesAHelperThroughItsAppsEntry() {
        let result = AllowList.setting(false, for: ["com.example.c.helper", "com.example.new"], in: helperList())
        XCTAssertTrue(result.changed)
        XCTAssertEqual(result.missing, ["com.example.new"])
        let entry = result.list[5] as? [String: Any]
        XCTAssertEqual(entry?["isAllowed"] as? Bool, false)
        XCTAssertEqual(AllowList.itemBundleIDs(of: entry ?? [:]), ["com.example.c.helper"])
        // The other entries are untouched.
        XCTAssertEqual(AllowList.entries(in: result.list).map(\.isAllowed), [true, false, false])
    }

    func testAppAndHelperInOneCall() {
        let result = AllowList.setting(false, for: ["com.example.c", "com.example.c.helper"], in: helperList())
        XCTAssertTrue(result.missing.isEmpty)
        XCTAssertEqual(AllowList.entries(in: result.list).map(\.isAllowed), [true, false, false])
    }

    /// A helper with an entry of its own that is also listed under its app's entry.
    private func doubleList() -> [Any] {
        helperList() + [
            key("com.example.c.helper"),
            ["isAllowed": true, "location": key("com.example.c.helper"), "menuItemLocations": [key("com.example.c.helper")]],
        ]
    }

    func testPrefersAnAppsOwnEntry() {
        XCTAssertEqual(AllowList.entry(for: "com.example.c.helper", in: doubleList())?.bundleID, "com.example.c.helper")
    }

    func testAnAppWithItsOwnEntryIsSwitchedByItAlone() {
        // Another app's entry listing it is left alone, with that app's items.
        let result = AllowList.setting(false, for: ["com.example.c.helper"], in: doubleList())
        XCTAssertEqual(AllowList.entries(in: result.list).map(\.isAllowed), [true, false, true, false])
        XCTAssertEqual(AllowList.isAllowed("com.example.c.helper", in: result.list), false)
        XCTAssertEqual(AllowList.isAllowed("com.example.c", in: result.list), true)
        XCTAssertEqual(AllowList.sharing("com.example.c.helper", in: doubleList()), [])
        XCTAssertEqual(AllowList.sharing("com.example.c", in: doubleList()), [])
    }

    func testAllowedIfAnyOfItsEntriesAllows() {
        // Two apps both list the helper, which has no entry of its own.
        let list = helperList() + [
            key("com.example.d"),
            ["isAllowed": false, "location": key("com.example.d"), "menuItemLocations": [key("com.example.c.helper")]],
        ]
        XCTAssertEqual(AllowList.isAllowed("com.example.c.helper", in: list), true)
        let off = AllowList.setting(false, for: ["com.example.c.helper"], in: list).list
        XCTAssertEqual(AllowList.isAllowed("com.example.c.helper", in: off), false)
        XCTAssertNil(AllowList.isAllowed("com.example.new", in: list))
    }

    func testListingAppsOfHelpers() {
        XCTAssertEqual(AllowList.listingApps(in: helperList()), ["com.example.c.helper": "com.example.c"])
        // A helper with an entry of its own goes by it.
        XCTAssertEqual(AllowList.listingApps(in: doubleList()), [:])
    }

    func testAppsSharingASwitch() {
        XCTAssertEqual(AllowList.sharing("com.example.c.helper", in: helperList()), ["com.example.c"])
        XCTAssertEqual(AllowList.sharing("com.example.c", in: helperList()), ["com.example.c.helper"])
        XCTAssertEqual(AllowList.sharing("com.example.a", in: helperList()), [])
        XCTAssertEqual(AllowList.sharing("com.example.new", in: helperList()), [])
    }

    func testSwitchesOnlyIsAllowedAndKeepsEveryOtherField() {
        let result = AllowList.setting(false, for: ["com.example.a"], in: list())
        XCTAssertTrue(result.changed)
        XCTAssertTrue(result.missing.isEmpty)
        let entry = result.list[1] as? [String: Any]
        XCTAssertEqual(entry?["isAllowed"] as? Bool, false)
        XCTAssertNotNil(entry?["location"])
        XCTAssertNotNil(entry?["menuItemLocations"])
        // The other app is untouched, its unusual location included.
        let other = result.list[3] as? [String: Any]
        let locations = other?["menuItemLocations"] as? [[String: Any]]
        XCTAssertNotNil(locations?.first?["adhocBinary"])
    }

    func testNoChangeWhenAlreadySet() {
        let result = AllowList.setting(false, for: ["com.example.b"], in: list())
        XCTAssertFalse(result.changed)
    }

    func testReportsAppsWithoutEntryAndNeverAddsOne() {
        let result = AllowList.setting(false, for: ["com.example.a", "com.example.new"], in: list())
        XCTAssertEqual(result.missing, ["com.example.new"])
        XCTAssertEqual(result.list.count, 4)
    }
}

final class MenuBarGeometryTests: XCTestCase {
    // A 1470 × 878 display with a 24-point menu bar, Cocoa coordinates.
    private let bar = CGRect(x: 0, y: 854, width: 1470, height: 24)
    private let dot = CGRect(x: 1200, y: 854, width: 32, height: 24)

    func testInsertionIndexFollowsItemCentres() {
        let frames = [CGRect(x: 1000, y: 854, width: 38, height: 24), CGRect(x: 1038, y: 854, width: 38, height: 24)]
        XCTAssertEqual(MenuBarGeometry.insertionIndex(at: 990, among: frames), 0)
        XCTAssertEqual(MenuBarGeometry.insertionIndex(at: 1030, among: frames), 1)
        XCTAssertEqual(MenuBarGeometry.insertionIndex(at: 1060, among: frames), 2)
        XCTAssertEqual(MenuBarGeometry.insertionIndex(at: 500, among: []), 0)
    }

    func testMenusHangingFromTheMenuBar() {
        let statusMenu = CGRect(x: 1150, y: 760, width: 160, height: 92)
        let contextMenu = CGRect(x: 400, y: 300, width: 160, height: 120)
        XCTAssertEqual(MenuBarGeometry.menuBarMenus([statusMenu, contextMenu], menuBars: [bar]), [statusMenu])
    }

    func testOverlaysCoveringTheMenuBarAreNotMenus() {
        // An invisible full-screen window at the menu level, as overlay utilities keep.
        let overlay = CGRect(x: 0, y: 0, width: 1470, height: 878)
        let strip = CGRect(x: 0, y: 850, width: 1470, height: 28)
        // Measured: a status item's menu hangs 1 point below the bar.
        let statusMenu = CGRect(x: 691, y: 854 - 1 - 93, width: 175, height: 93)
        XCTAssertEqual(MenuBarGeometry.menuBarMenus([overlay, strip, statusMenu], menuBars: [bar]), [statusMenu])
        XCTAssertTrue(MenuBarGeometry.isOutside(CGPoint(x: 300, y: 400), menuBars: [bar], menus: [overlay]))
        XCTAssertTrue(MenuBarGeometry.coversMenuBar(overlay, menuBars: [bar]))
        XCTAssertTrue(MenuBarGeometry.coversMenuBar(strip, menuBars: [bar]))
        XCTAssertFalse(MenuBarGeometry.coversMenuBar(statusMenu, menuBars: [bar]))
        // A popover or panel elsewhere on screen does not cover it either.
        XCTAssertFalse(MenuBarGeometry.coversMenuBar(CGRect(x: 400, y: 300, width: 300, height: 200), menuBars: [bar]))
    }

    func testOutsideClicks() {
        let menu = CGRect(x: 1150, y: 760, width: 160, height: 92)
        let drawer = CGRect(x: 1100, y: 810, width: 200, height: 38)
        XCTAssertFalse(MenuBarGeometry.isOutside(CGPoint(x: 700, y: 866), menuBars: [bar], menus: []))
        XCTAssertFalse(MenuBarGeometry.isOutside(CGPoint(x: 1200, y: 800), menuBars: [bar], menus: [menu]))
        XCTAssertFalse(MenuBarGeometry.isOutside(CGPoint(x: 1150, y: 820), menuBars: [bar], menus: [], keep: [drawer]))
        XCTAssertTrue(MenuBarGeometry.isOutside(CGPoint(x: 700, y: 400), menuBars: [bar], menus: [menu], keep: [drawer]))
    }

    func testDrawerHangsUnderTheDotInsideTheScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 878)
        let origin = MenuBarGeometry.drawerOrigin(size: CGSize(width: 120, height: 38), under: dot, in: screen)
        XCTAssertEqual(origin.x, 1156)
        XCTAssertEqual(origin.y, 854 - 6 - 38)
        // Near the right edge it is pushed back inside.
        let edgeDot = CGRect(x: 1440, y: 854, width: 28, height: 24)
        let pushed = MenuBarGeometry.drawerOrigin(size: CGSize(width: 120, height: 38), under: edgeDot, in: screen)
        XCTAssertEqual(pushed.x, 1470 - 8 - 120)
    }
}

final class PreferredPositionsTests: XCTestCase {
    private let positions: [String: Double] = [
        "module:Clock": 0,
        "status:com.example.app::Item-0": 213,
        "status:com.example.app::Item-1": 251,
        "status:com.example.application::Item-0": 175,
    ]

    func testKeysMatchTheWholeBundleID() {
        XCTAssertEqual(PreferredPositions.keys(of: "com.example.app", in: positions),
                       ["status:com.example.app::Item-0", "status:com.example.app::Item-1"])
        XCTAssertEqual(PreferredPositions.position(of: "com.example.application", in: positions), 175)
        XCTAssertNil(PreferredPositions.position(of: "com.example.other", in: positions))
    }

    func testBetweenNeighbours() {
        XCTAssertEqual(PreferredPositions.between(251, and: 213), 232)
        XCTAssertEqual(PreferredPositions.between(nil, and: 213), 214)
        XCTAssertEqual(PreferredPositions.between(117, and: nil), 116)
        XCTAssertEqual(PreferredPositions.between(1, and: nil), 0.5)
        XCTAssertNil(PreferredPositions.between(nil, and: nil))
    }
}
