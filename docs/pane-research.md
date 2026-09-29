# Split-pane focus via Accessibility — research findings (29 Sep 2026)

Measured on a MacBook Air (M4, macOS 15.6) with:
**Cursor 3.19.13** (`com.todesktop.230313mzl4w4u92`, both its default "glass" Agents window and the classic IDE window),
**Xcode 26.3** (`com.apple.dt.Xcode`), **Terminal.app** (`com.apple.Terminal`). All tests were run from an Accessibility-trusted Terminal.

## TL;DR

| App | Panes found by | Pane rect | Focus method that works | Which pane is focused |
|---|---|---|---|---|
| Cursor classic IDE | `AXTextArea`/`AXTextField` whose `AXDOMClassList` has `inputarea` (Monaco editor), `xterm-helper-textarea` (terminal), `aislash-editor-input` (chat) | exclusive-ancestor region (= the `split-view-view` group) | `AXFocused = true` on the input element ✅ (5/5 panes) | app `AXFocusedUIElement` == input (only while Cursor is active) |
| Cursor glass (Agents window, default in Cursor 3) | same classes + `ProseMirror` (agent prompt) | exclusive-ancestor region; prompt is a floating overlay → hit-test smallest region first | `AXFocused = true` ✅ | same |
| Xcode | native `AXTextArea` (desc `"Source Editor"`) | exclusive-ancestor region (= `AXGroup` identifier `"editor context"`, includes jump bar) | `AXFocused = true` ✅ (works even while Xcode is in the background) | `AXFocusedUIElement` == text area (reported even in background) |
| Terminal.app | native `AXTextArea` desc `"shell"` inside `AXScrollArea` | the `AXScrollArea` | `AXFocused = true` ✅ | same |

**Terminal.app split panes are two views of the SAME session** (one tab, one tty `/dev/ttys015`, identical `AXValue`). Pane focus changes only which view scrolls; keystrokes go to the same shell. → Treat Terminal.app as whole-window; don't bother with pane targeting there.

**Click fallback was never needed** (AXFocused worked everywhere), but it was verified to work: synthetic left click at the region centre + `CGWarpMouseCursorPosition(saved)` focuses the pane (Terminal test: pane 0 → 0, pane 1 → 1).

## Generic algorithm (works for all three apps)

1. Get the target window (`AXFocusedWindow`, or the window you already resolved from the CG window id).
2. **Electron apps only:** set `AXManualAccessibility = true` on the *application* element (without it the Cursor window exposes 12 nodes: just native frame views, no web content). `AXEnhancedUserInterface` was not needed.
3. Flatten the window's tree (keep parent links), reading `AXRole`, `AXPosition`/`AXSize`, and for Electron `AXDOMClassList` (array of strings — Chromium exposes the DOM class list).
4. **Pane inputs:**
   - Electron: role `AXTextArea` or `AXTextField` whose class list intersects `{"inputarea", "xterm-helper-textarea", "aislash-editor-input", "ProseMirror"}`. Don't match on `AXDescription` — Monaco's desc flips between `"The editor is not accessible at this time…"` and `"alpha.txt, Editor Group 1"` depending on screen-reader mode.
   - Native (Xcode, Terminal): role `AXTextArea`.
   - Drop hidden ones: any ancestor with width or height ≤ 2 (Monaco keeps a 1×1 `monaco-editor` in a `cursor-solid-portal`; hidden tabs are 0/1-px). Don't use a larger threshold: xterm's `xterm-helpers` parent is only 7×14.
5. **Pane region = exclusive ancestor:** walk up from each input while the ancestor contains no *other* pane input; the last such ancestor's frame is the pane rect. This yields exactly the visible pane areas (Monaco's input is a 1×17 px caret-sized textarea and xterm's is 7×14, so the input's own frame is useless).
6. **Hit-test by smallest area first** (Cursor glass puts the agent prompt as a floating overlay `560×76` over a terminal region `1280×800`).
7. **Focus:** `AXUIElementSetAttributeValue(input, kAXFocusedAttribute, kCFBooleanTrue)`. Order vs activation doesn't matter: setting it while Cursor was in the background took effect once Cursor was activated (Chromium reports `AXFocusedUIElement = nil` while backgrounded, so verify *after* activating).
8. **Verify:** read the app's `kAXFocusedUIElementAttribute` and `CFEqual` it with the input. For Electron the DOM also flips: `monaco-editor … focused`, `terminal xterm focus`, `terminal-wrapper active focus`.
9. **Fallback (only if verify fails, and only for allowlisted terminal/editor bundle ids):** click region centre, restore pointer.

Note `AXFocused` *settable* is reported false on the element that is already focused (Xcode) — don't use `AXUIElementIsAttributeSettable` as a filter.

### Swift (tested, from `panefinder.swift`)

```swift
func attr(_ el: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; return AXUIElementCopyAttributeValue(el, n as CFString, &v) == .success ? v : nil }
func frame(_ el: AXUIElement) -> CGRect? {
    guard let pv = attr(el, kAXPositionAttribute), let sv = attr(el, kAXSizeAttribute) else { return nil }
    var p = CGPoint.zero, s = CGSize.zero
    AXValueGetValue(pv as! AXValue, .cgPoint, &p); AXValueGetValue(sv as! AXValue, .cgSize, &s)
    return CGRect(origin: p, size: s)
}
struct Node { let el: AXUIElement; let parent: Int?; let role: String; let frame: CGRect?; let cls: [String] }

// Electron detection (Cursor, VS Code family): bundle contains the Electron framework.
let isElectron = FileManager.default.fileExists(atPath: app.bundleURL!
    .appendingPathComponent("Contents/Frameworks/Electron Framework.framework").path)
if isElectron { AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue) }

var nodes: [Node] = []
func walk(_ el: AXUIElement, _ parent: Int?, _ depth: Int) {
    let role = attr(el, kAXRoleAttribute) as? String ?? "?"
    let idx = nodes.count
    nodes.append(Node(el: el, parent: parent, role: role, frame: frame(el),
                      cls: isElectron ? (attr(el, "AXDOMClassList") as? [String] ?? []) : []))
    guard depth < 80 else { return }
    for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, idx, depth + 1) }
}
walk(window, nil, 0)

let electronInputClasses: Set<String> = ["inputarea", "xterm-helper-textarea", "aislash-editor-input", "ProseMirror"]
func isPaneInput(_ n: Node) -> Bool {
    guard n.role == "AXTextArea" || n.role == "AXTextField" else { return false }
    return isElectron ? !electronInputClasses.isDisjoint(with: n.cls) : n.role == "AXTextArea"
}
func ancestors(_ i: Int) -> [Int] { var r: [Int] = []; var j = nodes[i].parent; while let k = j { r.append(k); j = nodes[k].parent }; return r }
func visible(_ i: Int) -> Bool { !ancestors(i).contains { if let f = nodes[$0].frame { return f.width <= 2 || f.height <= 2 }; return false } }

let inputs = nodes.indices.filter { isPaneInput(nodes[$0]) && visible($0) }
let ancSets = inputs.map { Set(ancestors($0)) }
var panes: [(input: Int, region: Int)] = []
for (a, i) in inputs.enumerated() {
    var region = i
    for anc in ancestors(i) {
        if inputs.indices.contains(where: { $0 != a && ancSets[$0].contains(anc) }) { break }
        region = anc
    }
    panes.append((i, region))           // pane rect = nodes[region].frame
}

// focus + verify
AXUIElementSetAttributeValue(nodes[p.input].el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
let now = attr(appEl, kAXFocusedUIElementAttribute).map { $0 as! AXUIElement }
let ok = now.map { CFEqual($0, nodes[p.input].el) } ?? false

// click fallback (restores pointer; CGWarp does not count as user mouse activity)
let saved = CGEvent(source: nil)?.location ?? .zero
let src = CGEventSource(stateID: .hidSystemState)
CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(20_000)
CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: c, mouseButton: .left)?.post(tap: .cghidEventTap)
usleep(20_000)
CGWarpMouseCursorPosition(saved)
```

## Per app detail

### Cursor — classic IDE window (`cursor --classic`, or File ▸ New Window)
Test layout: two editor groups side by side, terminal panel split in two, Cursor chat in the aux bar.
`panefinder` output (window 245,184 1280×800):
```
0 inputarea              region split-view-view (521,216 276x503)   Editor Group 1
1 inputarea              region split-view-view (797,216 277x503)   Editor Group 2
2 xterm-helper-textarea  region split-view-view (521,751 221x213)   Terminal 1
3 xterm-helper-textarea  region split-view-view (742,751 221x213)   Terminal 2
4 aislash-editor-input   region split-view-view (1073,216 452x748)  Chat (aux bar)
```
Focusing each via AXFocused: all 5 verified. Tree hints: editor area `AXGroup sub=AXLandmarkMain cls="part editor"`; chat `cls="part editor embedded-aux-bar-editor"`; Monaco container `AXGroup sub=AXCodeStyleGroup cls="monaco-editor …"` (its frame = visible editor minus tabs); terminal `cls="terminal xterm"` in `cls="terminal-wrapper active"`. Explorer sidebar contains no pane input, so it belongs to no pane (gaze there = no pane change).

### Cursor — glass "Cursor Agents" window (Cursor 3 default)
Different DOM (`glass-*` / `ui-*` classes). Layout is a tiling system: each tile is `AXGroup sub=AXApplicationGroup desc="Panel <id>" cls="ui-tiling-panel …"` (e.g. `Panel editor-panel-group`, `Panel panel-<uuid>` for a terminal tile). Tabs inside a tile are `AXRadioButton sub=AXTabButton`, only the selected tab's `AXTabPanel` content is in the tree. Inputs: Monaco `inputarea`, xterm `xterm-helper-textarea`, agent prompt `AXTextArea cls="tiptap ProseMirror ui-prompt-input-editor__input …"`. When the chat is fullscreen the prompt lives in `AXGroup sub=AXLandmarkRegion desc="Fullscreen agent prompt" cls="agent-panel editor-panel-fullscreen-overlay"` floating over the tiles → smallest-region-first hit test. AXFocused verified on Monaco ↔ xterm ↔ ProseMirror (DOM `focused`/`focus` classes flip).
Editor split with ⌘\ did nothing in the glass window; ⌃` opens a terminal (as a tile or tab).

### Xcode
`AXWindow id=Xcode.WorkspaceWindow` › … › per editor: `AXGroup id="editor context" desc="<file>"` (pane rect incl. jump bar, e.g. 155,123 399×750) › `AXSplitGroup` › `AXScrollArea` (visible viewport) › `AXTextArea desc="Source Editor"` (frame = text content height, can be shorter than the viewport → don't use it as the rect). Exclusive-ancestor lands on the "editor context" group. AXFocused verified both ways, including while Xcode was in the background. Split made with ⌃⌘T (for a standalone file there was no "Add Editor" item in the Editor menu; pressing the jump bar's `AXMenuButton id="add editor"` via AXPress did nothing). Real project windows will also expose the debug console as an `AXTextArea` (a legit pane) — and big navigators (see performance).

### Terminal.app
`AXWindow` › `AXSplitGroup` › two `AXScrollArea` (+ `AXSplitter`) › `AXTextArea desc="shell"`. AXFocused and click both work, but both views are the same session (see TL;DR) → whole-window only.

## Gotchas

1. **Turning on `AXManualAccessibility` makes Cursor think a screen reader is running.** VS Code's `editor.accessibilitySupport: "auto"` flipped the status bar to **"Screen Reader Optimized"** and showed a toast *"Screen reader usage detected. Do you want to enable…"* (the terminal's desc changed to "Use ⌥F1 for terminal accessibility help"). This changes editor behaviour for the user. Recommendation: Headway's Settings tell the user to set `"editor.accessibilitySupport": "off"` in Cursor (and VS Code-family) settings. Evidence that panes still work with it off: before Monaco switched modes, its textarea (desc "The editor is not accessible at this time…") was already present and AXFocused worked on it. (Not yet re-tested with the setting explicitly off.) Chromium keeps its accessibility tree on for the rest of the process lifetime once enabled (some CPU cost in big DOMs).
2. **Tree is a stub for ~1–2 s** after first enabling `AXManualAccessibility` (first read: 13 nodes; 2 s later: ~100–500). Also right after Cursor launches. Enable it once per Electron app (on first sight / app launch) and retry the pane scan later instead of concluding "no panes".
3. **Walk cost:** Cursor classic 500 nodes ≈ 20–55 ms; Cursor glass 70–150 nodes ≈ 10–30 ms; Terminal 20 nodes ≈ 2–6 ms; **Xcode ≈ 0.45 ms/node** (60 nodes ≈ 27 ms; a real project navigator could be thousands of rows = seconds). → Don't scan every frame: scan the gazed window on demand, cache for ~1 s, run off the main thread, prune subtrees with roles `AXOutline`, `AXTable`, `AXList`, `AXBrowser`, `AXRow`, `AXMenuBar`, `AXToolbar` and don't descend into `AXTextArea`/`AXStaticText`/`AXButton`/`AXImage`; cap ~3000 nodes. Set `AXUIElementSetMessagingTimeout(appEl, 0.25)` so a busy/hung app (Xcode indexing) can't block for the default ~6 s.
4. **Chromium returns `AXFocusedUIElement = nil` while the app is in the background**; Xcode/Terminal still report it. Determine "which pane is focused" only for the frontmost app (or from DOM `focused`/`focus` classes for Electron).
5. **Activation is not guaranteed.** Three consecutive `AXFrontmost = true` calls (each returned success) left Terminal frontmost; minutes later the same call and `NSRunningApplication.activate(options: [])` both worked. → After activating, check `NSWorkspace.shared.frontmostApplication` and retry once with the other method.
6. **Synthetic clicks count as mouse activity** (`CGEventSource.secondsSinceLastEventType(.combinedSessionState, .leftMouseDown)` resets) → Headway must ignore its own clicks for the 1.5 s mouse-priority rule and for click-learning. **`CGWarpMouseCursorPosition` does NOT reset** `mouseMoved`/`leftMouseDown` idle times.
7. **No Screen Recording permission** (Terminal doesn't have it; Headway won't either): `CGWindowListCopyWindowInfo` omits `kCGWindowName` and `screencapture` shows only wallpaper. Window titles must come from AX (`kAXTitleAttribute`).
8. **Windows on other Spaces are absent from `AXWindows`** (Cursor reported 0 AX windows once the user switched Spaces, while CGWindowList still listed them with `onscreen 0`).
