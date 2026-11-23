import Foundation
import UsageCore

/// A one-shot timer the expander can cancel. Injected so tests run without waiting.
@MainActor
protocol OneShotScheduling {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any OneShotToken
}

@MainActor
protocol OneShotToken {
    func cancel()
}

/// The real scheduler: a main-actor task that sleeps.
struct TaskScheduler: OneShotScheduling {
    func schedule(after seconds: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> any OneShotToken {
        TaskToken(task: Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            fire()
        })
    }

    private struct TaskToken: OneShotToken {
        let task: Task<Void, Never>
        func cancel() { task.cancel() }
    }
}

/// Click handling for the status item (plan.md "Gauge design", Menubar setting).
///
/// - Normal: every click opens the dropdown.
/// - Compact: a click while collapsed expands into the logos and % for 3 s and opens
///   the dropdown at the same time (user, 2026-11-23); then the item collapses. A
///   click while expanded toggles the dropdown, as in Normal, and leaves the 3 s
///   deadline as it was.
/// - With nothing to show (`hasEntries == false`), a click opens the dropdown
///   directly, since expanding would show nothing.
@MainActor
final class CompactExpander {
    enum State: Equatable {
        case collapsed
        case expanded
    }

    enum ClickResult: Equatable {
        case expandedAndOpened
        case openDropdown
    }

    static let expandDuration: TimeInterval = 3

    private(set) var state: State = .collapsed
    /// Changing the style collapses the item and cancels the timer.
    var style: MenubarStyle {
        didSet { if style != oldValue { setState(.collapsed) } }
    }
    /// Whether there are providers to expand into. The controller keeps it current.
    var hasEntries = true
    /// Called after every state change, including the timer's collapse.
    var onStateChange: (() -> Void)?
    var onOpenDropdown: (() -> Void)?

    private let scheduler: any OneShotScheduling
    private var collapseToken: (any OneShotToken)?

    init(style: MenubarStyle, scheduler: any OneShotScheduling) {
        self.style = style
        self.scheduler = scheduler
    }

    /// Whether the item draws the providers (true) or the compact glyph (false).
    var showsProviders: Bool { style == .normal || state != .collapsed }

    @discardableResult
    func click() -> ClickResult {
        if style == .compact, state == .collapsed, hasEntries {
            setState(.expanded)
            collapseToken = scheduler.schedule(after: Self.expandDuration) { [weak self] in
                self?.setState(.collapsed)
            }
            // Expand first, so the dropdown opens under the widened item.
            onOpenDropdown?()
            return .expandedAndOpened
        }
        onOpenDropdown?()
        return .openDropdown
    }

    private func setState(_ new: State) {
        collapseToken?.cancel()
        collapseToken = nil
        guard new != state else { return }
        state = new
        onStateChange?()
    }
}
