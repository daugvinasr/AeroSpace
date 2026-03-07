import AppKit
import Common
import CoreGraphics

@MainActor private var focusFollowsMouseMonitor: Any? = nil
@MainActor private var focusFollowsMouseTask: Task<(), any Error>? = nil
@MainActor private var focusFollowsMouseWorkspaceSwitchTask: Task<(), any Error>? = nil
@MainActor private var focusFollowsMouseSuppressedUntil: Date = .distantPast

@MainActor
func handleWorkspaceSwitchForFocusFollowsMouse(to newWorkspace: Workspace, now: Date = .now) {
    guard config.focusFollowsMouse else { return }

    focusFollowsMouseWorkspaceSwitchTask?.cancel()
    let delayMs = config.focusFollowsMouseWorkspaceSwitchDelayMs
    focusFollowsMouseSuppressedUntil = now.addingTimeInterval(Double(delayMs) / 1000)
    focusFollowsMouseWorkspaceSwitchTask = Task { @MainActor in
        try await Task.sleep(for: .milliseconds(delayMs))
        try checkCancellation()
        guard focus.workspace == newWorkspace else { return }
        handleMouseMoveForFocusFollows(restrictToWorkspace: newWorkspace)
    }
}

@MainActor
func isFocusFollowsMouseSuppressed(now: Date = .now) -> Bool {
    now < focusFollowsMouseSuppressedUntil
}

@MainActor
func installFocusFollowsMouseMonitor() {
    if let monitor = focusFollowsMouseMonitor {
        NSEvent.removeMonitor(monitor)
        focusFollowsMouseMonitor = nil
    }
    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = nil
    focusFollowsMouseWorkspaceSwitchTask?.cancel()
    focusFollowsMouseWorkspaceSwitchTask = nil

    if !config.focusFollowsMouse { return }

    focusFollowsMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
        Task { @MainActor in
            handleMouseMoveForFocusFollows()
        }
    }
}

/// CGWindowListCopyWindowInfo returns windows in front-to-back order so first
/// returned window is visually the topmost one.
@MainActor
func resolveTopmostWindowUnderCursor(_ point: CGPoint, on workspace: Workspace? = nil) -> Window? {
    let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
    guard let cfArray = CGWindowListCopyWindowInfo(options, CGWindowID(0)) as? [CFDictionary] else { return nil }
    for elem in cfArray {
        let dict = elem as NSDictionary
        guard let _windowId = dict[kCGWindowNumber] else { continue }
        let windowId = ((_windowId as! CFNumber) as NSNumber).uint32Value
        guard let window = Window.get(byId: windowId) else { continue }
        guard let boundsDict = dict[kCGWindowBounds] else { continue }
        guard let bounds = CGRect(dictionaryRepresentation: boundsDict as! CFDictionary) else { continue }
        if bounds.contains(point) {
            if let workspace, window.visualWorkspace != workspace { continue }
            return window
        }
    }
    return nil
}

@MainActor
private func handleMouseMoveForFocusFollows(restrictToWorkspace workspace: Workspace? = nil) {
    guard let token: RunSessionGuard = .isServerEnabled else { return }
    guard !isLeftMouseButtonDown else { return }
    guard !isFocusFollowsMouseSuppressed() else { return }

    let mouseLocation = mouseLocation
    let targetWindow = resolveTopmostWindowUnderCursor(mouseLocation)

    guard let targetWindow else { return }
    guard targetWindow.windowId != focus.windowOrNil?.windowId else { return }
    guard let targetWorkspace = targetWindow.visualWorkspace else { return }
    guard targetWorkspace.isVisible else { return }
    if let workspace {
        guard targetWorkspace == workspace else { return }
    }

    focusFollowsMouseTask?.cancel()
    focusFollowsMouseTask = Task {
        try checkCancellation()
        try await runLightSession(.focusFollowsMouse, token) {
            _ = targetWindow.focusWindow()
            targetWindow.nativeFocus()
        }
    }
}
