import AppKit
import Observation
import SwiftUI
import UsageCore

/// The model the popover shows; the integrator pushes each new `DashboardModel`.
@MainActor
@Observable
final class DropdownState {
    var model: DashboardModel?
    var timeZone: TimeZone = .current
    /// Added to wall time for ages and countdowns (`--now` in development).
    var clockOffset: TimeInterval = 0
}

/// Ticks once a minute so ages and countdowns move while the popover is open.
struct DropdownRootView: View {
    let state: DropdownState

    var body: some View {
        TimelineView(.everyMinute) { context in
            DropdownView(model: state.model,
                         clock: DropdownClock(now: context.date.addingTimeInterval(state.clockOffset),
                                              timeZone: state.timeZone))
        }
    }
}

/// The dropdown as an `NSPopover` hosting SwiftUI. Not wired yet: the integrator
/// attaches it to the status item button (`toggle(relativeTo:)`) and calls `show(_:)`
/// with every published model.
@MainActor
final class DropdownPopover {
    let popover = NSPopover()
    let state = DropdownState()

    init() {
        let host = NSHostingController(rootView: DropdownRootView(state: state))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
    }

    func show(_ model: DashboardModel) {
        state.model = model
    }

    var isShown: Bool { popover.isShown }

    /// Opens under `view` (the status item button), or closes when already open.
    func toggle(relativeTo view: NSView) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func close() {
        popover.performClose(nil)
    }
}
