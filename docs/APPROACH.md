# How Chest works

Notes on the approach, the alternatives that were ruled out, and what was measured, all on macOS 27.0.1. The code: `MenuBarSwitches` (hiding), `MenuBarPositions` (placing), `MenuBarItems` (reading and pressing items), `ChestController` (the dot, drag and drop, the drawer), `ChestCore` (pure logic with tests).

## Why the old approach broke

Ice hid items with a divider status item about 10,000 points wide that pushed everything left of it off screen. macOS 27 moved menu bar layout into a system process, `MenuBarAgent`, which draws every item into one window per menu bar. It places a wide item only while it fits, draws items that do not fit on top of it, and never pushes anything off screen.

## Approaches considered

### Assessment-mode restriction (Ellipsis, Thaw, holzBar)

`MenuBarAgent` serves the menu bar half of exam mode over XPC; the private framework `MenuBarClientCore` wraps it as `MBAssessmentModeConfiguration` and `MBAssessmentModeAssertion`. While an assertion is live, only allow-listed apps show items. No permission is needed, but:

- Focus and Control Center's camera, microphone and screen recording indicator disappear while anything is hidden. Only the small dot beside the clock stays.
- Every app that does not run from `/Applications` disappears too, whatever the allow list says (`~/Applications` does not count).
- The clock does not open Notification Center.
- The allow list is a snapshot of running apps, so new apps are hidden until it is renewed.

Ways around the indicator were looked for and not found. The XPC message carries an `origin`; 1 is assessment, 0 is accepted but hides nothing, 2 and up are rejected. System items go by name (`battery`, `bluetooth`, `clock`, `displays`, `keyboard`, `volume`, `wifi`, `screenMirroring`, `primaryBentoBox`) and none names the indicator. The services that deal with it (`HideAttachedAVModule`, `AVModuleProvider`) need Apple-only entitlements.

### A panel over the items

Leaves the system alone, but the items keep their space, the panel has to match a translucent, wallpaper-tinted menu bar, and clicks have to be blocked. Not pursued.

### System Settings' own switches (chosen)

System Settings › Menu Bar › Allow in the Menu Bar has a switch per app. Switching an app off removes its items and nothing else. Measured: with Do Not Disturb on, an app hidden this way left Focus in place (exam mode removed it); apps outside `/Applications` stayed; the clock still opened Notification Center.

## Hiding app items

The list lives in Control Center's group container:

```
~/Library/Group Containers/group.com.apple.controlcenter/Library/Preferences/group.com.apple.controlcenter.plist
key: trackedApplications (data: a binary property list)
```

The data is an array alternating keys and entries:

```
[ {bundle: {_0: "com.example.app"}},
  {isAllowed: true,
   location: {bundle: {_0: "com.example.app"}},
   menuItemLocations: [ {bundle: {_0: "com.example.app"}} ]},
  ... ]
```

An ad-hoc signed app outside `/Applications` has `{adhocBinary: {_0: {relative: "file:///…/MacOS/App"}}}` as its location instead.

- The container needs Full Disk Access.
- Writing through CFPreferences with the file's absolute path (what `defaults write <path>` does) goes through cfprefsd, and `MenuBarAgent` applies it within a second. `UserDefaults(suiteName: "group.com.apple.controlcenter")` does not work without Apple's app group entitlement: it reads and writes a different file.
- `MenuBarAgent` creates every entry and matches items by `menuItemLocations`. An entry written from scratch is ignored and replaced, so Chest only flips `isAllowed` on existing entries and writes every other field back untouched (`AllowList`, tested).
- An app has an entry once `MenuBarAgent` lists it, usually as soon as its item appears. An app it has seen before, or one whose entry was removed, is listed again when `MenuBarAgent` starts. So for an unlisted app Chest offers **Refresh Menu Bar**, which terminates `MenuBarAgent`; launchd starts it again at once and the menu bar blinks once.

Once, with about 70 apps in the list, `MenuBarAgent` stopped applying changes until it was restarted: the file had the new value and every item stayed where it was, for every app. The trigger was not found (a burst of 15 new apps, System Settings' Menu Bar page and repeated switching did not bring it back). So after switching items off, Chest checks a second and a half later that they left the menu bar, and if not restarts `MenuBarAgent` once (at most every 30 seconds), as Refresh Menu Bar does.

## Hiding system items

System items are not in the list. Each checkbox under Menu Bar Controls is backed by its own preference, which `MenuBarAgent` also applies live. To find one: toggle the checkbox in System Settings, compare the preferences before and after, then write each changed key alone to see which one takes. Mapped so far:

| Item | Owner in the menu bar | Switch |
|---|---|---|
| Spotlight | `com.apple.campo` | `MenuItemHidden` (bool, `true` hides) in `com.apple.Spotlight`, current host |

## Placing items

`MenuBarAgent` keeps a position for every item in the `com.apple.MenuBar` group container:

```
~/Library/Group Containers/com.apple.MenuBar/Library/Preferences/com.apple.MenuBar.plist
key: TrailingItemPreferredPositions (dictionary)
  "status:<bundle ID>::<autosave name>" => 213     an app's status item
  "module:Clock" => 0                              MenuBarAgent's own items
```

A position is a distance from the right end of the menu bar, so a larger one sits further left. A program run outside a bundle (`swift run`) is named by its process name instead of a bundle ID. The values are only rewritten when an item moves, so they can be stale, but their order matches the menu bar.

An item that is switched back on goes to its position. So Chest places an item dragged out of the drawer by writing a position halfway between its new neighbours' (`PreferredPositions`, tested) while the item is still switched off, then switching it on. Measured: written through CFPreferences with the file's absolute path, as with the allow list, it took effect the next time the item was switched on, between two items or at either end. Nothing is dragged on the user's behalf.

## Reading and opening items

`MenuBarAgent` exposes its menu bar windows over Accessibility, one per menu bar and Space. Each child of a window is a slot carrying the item's frame. An app item's slot holds an `AXApplication` element owned by the app; under it, the app's extras menu bar holds the item, an `AXMenuBarItem` with subrole `AXMenuExtra`. Neither the slot nor the application element takes `AXPress`; the menu extra does.

The app's own `AXExtrasMenuBar` (asked of the app, not `MenuBarAgent`) still holds the item while it is switched off, with its menu under it. Measured with menu, rebuilt-on-open, submenu and popover fixtures:

- Reading the menu's children makes the app update it, as it would before opening it (`menuNeedsUpdate` runs), so it is current.
- `AXPress` on an entry of the closed menu runs that entry, submenus included.
- `AXPress` on the item opens its real menu or popover where the item was last drawn, without the item coming back. Neither the item nor the opened menu can be moved (their position is not settable), and popovers are not Accessibility windows.

So a drawer item opens without coming back to the menu bar: Chest reads its menu and shows a copy under the drawer icon, and pressing an entry there presses the real one. An item without a menu (a popover) is pressed where it last was; an item dropped on the chest was last next to the dot, so that is near the drawer. Spotlight's item belongs to `com.apple.campo` and has no extras menu bar while switched off, so Chest sends Spotlight's keyboard shortcut (`com.apple.symbolichotkeys`, entry 64, ⌘-Space by default). An app that exposes no item while switched off falls back to the old way: switch it back on, `AXPress` it (or click it with a real HID-sourced click if it ignores the press), and switch it off once its menu or window closes. Menus are found in the window list as other apps' pop-up-menu-level windows whose top edge touches a menu bar (no permission needed).

## Drag and drop

A global mouse monitor watches for a ⌘-mouse-down in a menu bar, reads which item is under it, and tracks the drag. The dot cannot be the drop target: `MenuBarAgent` slides items aside to make room for the dragged one, so the dot moves out from under the pointer, and dropping on it or just left of it end the same way. So once the item is known, a chest panel hangs under the dot and the dot turns into a box while the pointer is over it.

- Released on the panel, the item goes into the drawer. Released below the menu bar, `MenuBarAgent` puts the item back in the bar at the pointer's x, and Chest switches it off about 0.05 s later.
- Released anywhere else, Chest reads where the item settled. Left of the dot it is hidden there; a hidden item moved right of the dot stays shown.

Right after an item is switched off, `MenuBarAgent` can still list it where the next item slides in, so a ⌘-drag started within about a second can be read as the item that just went. When the item read is one that should be away, Chest reads the drag's own window instead: while a ⌘-drag lasts, `MenuBarAgent` draws the item in a small window that rises above the top of the screen.

Items are dragged out of the drawer with Chest's own tracking, not a dragging session: a dragging session held over the top of the screen opens Mission Control.

## Permissions

- **Accessibility**: `AXIsProcessTrustedWithOptions` with the prompt adds Chest to the list.
- **Full Disk Access**: macOS lists an app here only after it tries to open a place that permission guards. Opening `~/Library/Mail` does; the privacy database and Safari's files do not. Reading Control Center's container is denied without listing the app, and macOS then keeps denying that process without asking again. So Chest opens the Mail folder first thing at launch (nothing is read), and the user finds Chest in the list ready to switch on. macOS then asks to quit and reopen it.
- Grants follow the code signature's designated requirement. An ad-hoc signature's requirement is the binary's hash, which every build changes, so `scripts/package.sh` gives an ad-hoc build `designated => identifier "app.boringbar.chest"`. Measured: grants survived a rebuild with a different hash. A Developer ID signature's default requirement (identifier and team) survives rebuilds as it is.

## UI notes

- The drawer and notices are non-activating panels at the pop-up menu level: the frontmost app keeps focus, as with a menu. Their buttons accept the first click.
- `MenuBarAgent` ignores a status item button's highlight, so the dot shows its open state with its own symbol (an empty ring).
- Ctrl-C and `kill` quit Chest normally (signal handlers call `NSApp.terminate`), so items come back. A force quit or crash cannot be caught.

## Testing notes

- Synthetic clicks on menu bar items need a HID-sourced event with a click state, or `MenuBarAgent` ignores them.
- A synthetic ⌘-drag that sets the Command flag without a key-up leaves Command held; post a key-up afterwards.
- Never send Escape while a terminal is frontmost if an agent is running in it. Bring another app forward and check it is frontmost first.
- For scale, run 50 or more fixtures: the menu bar collapses what does not fit behind `«`, and the drawer wraps.
- A status-item fixture app (one copy in `/Applications`, one elsewhere) covers both kinds of `menuItemLocations`. Give fixtures a static menu, a menu rebuilt in `menuNeedsUpdate` (with a submenu, a check mark and a key equivalent), and a popover, to cover the ways a drawer item opens.
- A synthetic drag that starts where nothing takes it can grab a window's title bar instead; dragged to the top of the screen, it opens Mission Control. Check the drawer is open first.
