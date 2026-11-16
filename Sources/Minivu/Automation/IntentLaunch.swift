import Foundation

/// Tells a launch made only to run a Shortcuts action apart from one the
/// user made, and keeps the first windowless (docs/feature-notes/sys.md,
/// "Launched by a shortcut").
///
/// macOS gives an app no documented sign that it was launched for an App
/// Intent: the launch looks like a plain one. What differs is what happens
/// next. A launch from the Dock, Finder, Launchpad or `open -a` activates
/// the app at once; a launch for an action with `openAppWhenRun = false`
/// doesn't, and the action's `perform()` starts instead. So, with no files
/// to open and the app not active when launching finishes, the browser
/// waits up to `decisionWindow` for one or the other. Whatever is unsure
/// fails safe: the timeout, an activation, a Dock click, a file to open or
/// Open in minivu all show the window, as before.
///
/// When an action came first, minivu stays windowless and out of the Dock
/// (`.accessory`), and quits through the normal quit path (which waits for
/// queued writes) once no action has run for `idleGrace`. Any quit also
/// waits for actions already running; one that begins while a quit waits,
/// or the user opening minivu meanwhile, cancels the quit (see
/// `quitWaits`), so no action is cut off and no window shown is quit
/// under; the idle quit comes round again.
final class IntentLaunch {
    enum Mode: Equatable {
        /// Before `applicationDidFinishLaunching`.
        case launching
        /// Waiting, at most `decisionWindow`, for an activation or an action.
        case deciding
        /// The browser is (being) shown: everything as before.
        case normal
        /// Launched for actions only: no window, no Dock icon.
        case intentOnly
    }

    /// Short enough not to be noticed if it times out on a launch the user
    /// made, long enough for the intent runtime's request to arrive.
    nonisolated static let decisionWindow: Duration = .milliseconds(300)
    /// A shortcut's steps, or the same Quick Action used on a few
    /// selections in a row, come within seconds of each other; a minute
    /// spares each a fresh launch, and an idle, windowless minivu costs
    /// little in that time.
    nonisolated static let idleGrace: Duration = .seconds(60)

    /// Runs `action` after a delay; the returned closure cancels it. Tests
    /// pass one they fire by hand.
    typealias Scheduler = @MainActor (Duration, @escaping () -> Void) -> () -> Void

    static let shared = IntentLaunch()

    private(set) var mode: Mode = .launching
    private(set) var running = 0
    private var actionBeforeDecision = false
    /// A quit is waiting for writes (`applicationShouldTerminate` returned
    /// `.terminateLater`), and whether an action or the user cancelled it.
    private(set) var quitting = false
    private var quitCancelled = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var cancelPending: (() -> Void)?
    private let schedule: Scheduler
    /// Set by the app delegate: show the browser (and switch to `.regular`),
    /// leave the Dock, quit.
    var showWindow: () -> Void = {}
    var hide: () -> Void = {}
    var quit: () -> Void = {}

    init(schedule: @escaping Scheduler = IntentLaunch.mainQueueScheduler) {
        self.schedule = schedule
    }

    static func mainQueueScheduler(_ delay: Duration, _ action: @escaping () -> Void) -> () -> Void {
        let task = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            action()
        }
        return { task.cancel() }
    }

    /// From `applicationDidFinishLaunching`. `windowRequested`: files to
    /// open, the app already active, or the snapshot harness.
    func launchFinished(windowRequested: Bool) {
        guard mode == .launching else { return }
        if windowRequested {
            becomeNormal()
        } else if actionBeforeDecision || running > 0 {
            becomeIntentOnly()
        } else {
            mode = .deciding
            replacePending(schedule(Self.decisionWindow) { [weak self] in self?.becomeNormal() })
        }
    }

    /// The user wants minivu: it was activated, its Dock icon clicked, a
    /// file opened in it, or Open in minivu run.
    func userAsked() {
        if mode == .deciding || mode == .intentOnly { becomeNormal() }
    }

    func actionBegan() {
        running += 1
        if quitting { quitCancelled = true }
        switch mode {
        case .launching: actionBeforeDecision = true
        case .deciding: becomeIntentOnly()
        case .intentOnly: replacePending(nil)
        case .normal: break
        }
    }

    func actionEnded() {
        running = max(running - 1, 0)
        guard running == 0 else { return }
        idleWaiters.forEach { $0.resume() }
        idleWaiters = []
        if mode == .intentOnly { scheduleQuit() }
    }

    /// Any quit (the idle one or ⌘Q) that waits before replying. A second
    /// terminate during the wait keeps the first one's cancellation.
    func quitWaits() {
        guard !quitting else { return }
        quitting = true
        quitCancelled = false
    }

    /// Returns once no action is running (a quit waits for them).
    func waitUntilNoActions() async {
        while running > 0 { await withCheckedContinuation { idleWaiters.append($0) } }
    }

    /// The reply to a waiting quit, checked synchronously just before it is
    /// given: an action that began during the wait, or the user opening
    /// minivu, cancels it. The action's work may have started after the
    /// waits had passed it (a rename registered after `waitForRenames`
    /// returned) and would be cut off. The idle quit is scheduled again when
    /// the action ends.
    func quitReply(_ proceed: Bool) -> Bool {
        defer { quitting = false; quitCancelled = false }
        return proceed && !quitCancelled && running == 0
    }

    /// Wraps an action's work (every intent but Open in minivu).
    static func run<T>(_ body: () async throws -> T) async rethrows -> T {
        shared.actionBegan()
        defer { shared.actionEnded() }
        return try await body()
    }

    private func becomeNormal() {
        replacePending(nil)
        mode = .normal
        if quitting { quitCancelled = true }
        showWindow()
    }

    private func becomeIntentOnly() {
        replacePending(nil)
        mode = .intentOnly
        hide()
        if running == 0 { scheduleQuit() }
    }

    private func scheduleQuit() {
        replacePending(schedule(Self.idleGrace) { [weak self] in
            guard let self, mode == .intentOnly, running == 0, !quitting else { return }
            quit()
        })
    }

    private func replacePending(_ cancel: (() -> Void)?) {
        cancelPending?()
        cancelPending = cancel
    }
}
