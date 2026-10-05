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
            .init(bundleID: "com.example.a", isAllowed: true),
            .init(bundleID: "com.example.b", isAllowed: false),
        ])
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
