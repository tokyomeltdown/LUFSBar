// Test helper: drives an app's interface through the accessibility API, so a
// test can press a control or read its value without a screenshot. Needs the
// Accessibility permission for whatever runs it.
// Usage: axui dump <pid>                 every element: role, title, description, value
//        axui press <pid> <title>        AXPress on the first element titled (or described) so
//        axui value <pid> <title>        prints that element's AXValue
//        axui statusitem <pid>           prints the menu bar item's frame: x y w h
//        axui click <x> <y> [right]      a synthetic mouse click at a screen point
// Exits 1 when the element is not found or the action fails.
import ApplicationServices
import Foundation

let args = CommandLine.arguments
func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success ? v : nil
}
func str(_ e: AXUIElement, _ name: String) -> String { (attr(e, name) as? String) ?? "" }
func children(_ e: AXUIElement) -> [AXUIElement] {
    var all: [AXUIElement] = []
    for name in [kAXChildrenAttribute, kAXWindowsAttribute, "AXExtrasMenuBar"] {
        if let list = attr(e, name) as? [AXUIElement] { all += list }
        else if let one = attr(e, name), CFGetTypeID(one) == AXUIElementGetTypeID() { all.append(one as! AXUIElement) }
    }
    return all
}
func walk(_ e: AXUIElement, depth: Int = 0, seen: inout Set<Int>, visit: (AXUIElement, Int) -> Bool) -> Bool {
    let key = Int(CFHash(e))
    guard depth < 30, !seen.contains(key) else { return false }
    seen.insert(key)
    if visit(e, depth) { return true }
    for child in children(e) where walk(child, depth: depth + 1, seen: &seen, visit: visit) { return true }
    return false
}
func find(_ pid: pid_t, _ title: String) -> AXUIElement? {
    var found: AXUIElement?
    var seen = Set<Int>()
    _ = walk(AXUIElementCreateApplication(pid), seen: &seen) { e, _ in
        if str(e, kAXTitleAttribute) == title || str(e, kAXDescriptionAttribute) == title { found = e; return true }
        return false
    }
    return found
}
func point(_ e: AXUIElement) -> (CGPoint, CGSize)? {
    guard let p = attr(e, kAXPositionAttribute), let s = attr(e, kAXSizeAttribute) else { return nil }
    var pt = CGPoint.zero, sz = CGSize.zero
    AXValueGetValue(p as! AXValue, .cgPoint, &pt)
    AXValueGetValue(s as! AXValue, .cgSize, &sz)
    return (pt, sz)
}

guard args.count >= 2 else { print("usage: see the top of axui.swift"); exit(2) }
switch args[1] {
case "dump":
    guard args.count == 3, let pid = pid_t(args[2]) else { exit(2) }
    var seen = Set<Int>()
    _ = walk(AXUIElementCreateApplication(pid), seen: &seen) { e, depth in
        let value = attr(e, kAXValueAttribute).map { "\($0)" } ?? ""
        print(String(repeating: "  ", count: depth) + "\(str(e, kAXRoleAttribute)) title=\"\(str(e, kAXTitleAttribute))\" desc=\"\(str(e, kAXDescriptionAttribute))\" value=\"\(value)\"")
        return false
    }
case "press", "value":
    guard args.count == 4, let pid = pid_t(args[2]) else { exit(2) }
    guard let e = find(pid, args[3]) else { print("no element titled \(args[3])"); exit(1) }
    if args[1] == "press" {
        let err = AXUIElementPerformAction(e, kAXPressAction as CFString)
        guard err == .success else { print("AXPress failed (\(err.rawValue))"); exit(1) }
    } else {
        print(attr(e, kAXValueAttribute).map { "\($0)" } ?? "")
    }
case "statusitem":
    guard args.count == 3, let pid = pid_t(args[2]) else { exit(2) }
    guard let bar = attr(AXUIElementCreateApplication(pid), "AXExtrasMenuBar"),
          let items = attr(bar as! AXUIElement, kAXChildrenAttribute) as? [AXUIElement],
          let item = items.first, let (p, s) = point(item) else { print("no menu bar item"); exit(1) }
    print("\(Int(p.x)) \(Int(p.y)) \(Int(s.width)) \(Int(s.height))")
case "click":
    guard args.count >= 4, let x = Double(args[2]), let y = Double(args[3]) else { exit(2) }
    let right = args.count == 5 && args[4] == "right"
    let at = CGPoint(x: x, y: y)
    let down = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: at, mouseButton: right ? .right : .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: at, mouseButton: right ? .right : .left)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: at, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(100_000)
    down?.post(tap: .cghidEventTap)
    usleep(80_000)
    up?.post(tap: .cghidEventTap)
default:
    print("unknown command \(args[1])"); exit(2)
}
