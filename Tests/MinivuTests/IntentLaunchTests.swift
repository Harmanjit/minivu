import Testing
import Foundation
import CoreServices
@testable import Minivu

/// The launch decision and the idle quit of a launch made for a Shortcuts
/// action (IntentLaunch), with a scheduler fired by hand: no process is
/// launched, no window shown, nothing quits.
@MainActor @Suite struct IntentLaunchTests {
    /// Timers the controller asked for, fired by the test.
    @MainActor final class FakeTimers {
        var timers: [(delay: Duration, action: () -> Void, cancelled: Bool)] = []
        var live: [Duration] { timers.filter { !$0.cancelled }.map(\.delay) }

        func schedule(_ delay: Duration, _ action: @escaping () -> Void) -> () -> Void {
            let index = timers.count
            timers.append((delay, action, false))
            return { [weak self] in self?.timers[index].cancelled = true }
        }

        /// Fires the live timers, as if their time had come.
        func fire() {
            for index in timers.indices where !timers[index].cancelled {
                timers[index].cancelled = true
                timers[index].action()
            }
        }
    }

    @MainActor final class Events {
        var log: [String] = []
    }

    func make() -> (IntentLaunch, FakeTimers, Events) {
        let timers = FakeTimers()
        let events = Events()
        let launch = IntentLaunch(schedule: { timers.schedule($0, $1) })
        launch.showWindow = { events.log.append("window") }
        launch.hide = { events.log.append("hide") }
        launch.quit = { events.log.append("quit") }
        return (launch, timers, events)
    }

    @Test func requestedWindowShowsAtOnce() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: true)
        #expect(launch.mode == .normal)
        #expect(events.log == ["window"])
        #expect(timers.live.isEmpty)
    }

    @Test func activationWhileDecidingShowsTheWindow() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        #expect(launch.mode == .deciding)
        #expect(timers.live == [IntentLaunch.decisionWindow])
        #expect(events.log.isEmpty)
        launch.userAsked()
        #expect(launch.mode == .normal)
        #expect(events.log == ["window"])
        #expect(timers.live.isEmpty)
    }

    /// Fails safe: with neither an activation nor an action, the window shows.
    @Test func timeoutShowsTheWindow() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        timers.fire()
        #expect(launch.mode == .normal)
        #expect(events.log == ["window"])
        // An action after that changes nothing.
        launch.actionBegan()
        launch.actionEnded()
        #expect(events.log == ["window"])
        #expect(timers.live.isEmpty)
    }

    @Test func actionWhileDecidingStaysWindowlessThenQuits() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        #expect(launch.mode == .intentOnly)
        #expect(events.log == ["hide"])
        #expect(timers.live.isEmpty)   // no quit while it runs
        launch.actionEnded()
        #expect(timers.live == [IntentLaunch.idleGrace])
        timers.fire()
        #expect(events.log == ["hide", "quit"])
    }

    /// The intent runtime's request can arrive before launching finishes,
    /// and the action can even be over by then.
    @Test func actionBeforeLaunchFinishedDecidesAtOnce() {
        let (launch, timers, events) = make()
        launch.actionBegan()
        launch.actionEnded()
        #expect(launch.mode == .launching)
        launch.launchFinished(windowRequested: false)
        #expect(launch.mode == .intentOnly)
        #expect(events.log == ["hide"])
        #expect(timers.live == [IntentLaunch.idleGrace])
    }

    /// The next step of a shortcut within the grace period keeps minivu,
    /// and the grace period starts again when it ends.
    @Test func anotherActionCancelsTheQuit() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        launch.actionBegan()
        #expect(timers.live.isEmpty)
        launch.actionBegan()
        launch.actionEnded()
        #expect(timers.live.isEmpty)   // one still running
        launch.actionEnded()
        #expect(timers.live == [IntentLaunch.idleGrace])
        timers.fire()
        #expect(events.log == ["hide", "quit"])
    }

    /// A Dock click, a file opened or Open in minivu during or after the
    /// actions: the browser, and no quit.
    @Test func userAskingAfterwardsShowsTheWindowAndStopsTheQuit() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        launch.userAsked()
        #expect(launch.mode == .normal)
        #expect(timers.live.isEmpty)
        timers.fire()
        #expect(events.log == ["hide", "window"])
    }

    @Test func userAskingDuringAnActionShowsTheWindowAndNeverQuits() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.userAsked()
        launch.actionEnded()
        #expect(timers.live.isEmpty)
        #expect(events.log == ["hide", "window"])
    }

    /// Already running normally: actions change nothing, and the user
    /// asking again shows no second window.
    @Test func normalLaunchIgnoresActions() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: true)
        launch.actionBegan()
        launch.actionEnded()
        launch.userAsked()
        #expect(events.log == ["window"])
        #expect(timers.live.isEmpty)
    }

    /// Activation or a file before launching finishes is left to the
    /// launch itself (the file is in `windowRequested`).
    @Test func userAskingBeforeLaunchFinishedDoesNothingYet() {
        let (launch, _, events) = make()
        launch.userAsked()
        #expect(launch.mode == .launching)
        #expect(events.log.isEmpty)
    }

    /// Every action but Open in minivu counts, and is counted out again
    /// when it throws.
    @Test func runCountsAndUncountsTheAction() async {
        let before = IntentLaunch.shared.running
        struct Failure: Error {}
        let inside = await IntentLaunch.run { IntentLaunch.shared.running }
        #expect(inside == before + 1)
        await #expect(throws: Failure.self) {
            try await IntentLaunch.run { throw Failure() }
        }
        #expect(IntentLaunch.shared.running == before)
    }

    /// An action that begins while the idle quit waits for writes cancels
    /// it (its work may start after the waits passed it); the idle quit
    /// comes round again when it ends.
    @Test func actionDuringTheQuitsWaitCancelsIt() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        timers.fire()
        #expect(events.log == ["hide", "quit"])
        launch.quitWaits()
        launch.actionBegan()
        #expect(launch.quitReply(true) == false)
        #expect(!launch.quitting)
        #expect(timers.live.isEmpty)   // not while it runs
        launch.actionEnded()
        #expect(timers.live == [IntentLaunch.idleGrace])
        timers.fire()
        #expect(events.log == ["hide", "quit", "quit"])
        // With nothing beginning meanwhile, the quit goes ahead.
        launch.quitWaits()
        #expect(launch.quitReply(true))
    }

    /// Begun and ended within the wait: still cancelled (its rename may
    /// have been registered after the wait for renames), and rescheduled.
    @Test func actionBegunAndEndedDuringTheWaitStillCancels() {
        let (launch, timers, _) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        timers.fire()
        launch.quitWaits()
        launch.actionBegan()
        launch.actionEnded()
        #expect(launch.quitReply(true) == false)
        #expect(timers.live == [IntentLaunch.idleGrace])
    }

    /// The same gate covers ⌘Q in a normal launch; it schedules nothing,
    /// and a quit the user cancelled stays cancelled.
    @Test func manualQuitIsGatedToo() {
        let (launch, timers, _) = make()
        launch.launchFinished(windowRequested: true)
        launch.quitWaits()
        #expect(launch.quitReply(true))
        launch.quitWaits()
        launch.actionBegan()
        launch.actionEnded()
        #expect(launch.quitReply(true) == false)
        #expect(timers.live.isEmpty)
        launch.quitWaits()
        #expect(launch.quitReply(false) == false)
        // An action outside any quit leaves the next one alone.
        launch.actionBegan()
        launch.actionEnded()
        launch.quitWaits()
        #expect(launch.quitReply(true))
    }

    /// Opening minivu while the idle quit waits for writes shows the
    /// browser and cancels that quit, so minivu doesn't quit under it.
    @Test func userAskingDuringTheQuitsWaitCancelsIt() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        timers.fire()
        launch.quitWaits()
        launch.userAsked()
        #expect(events.log == ["hide", "quit", "window"])
        #expect(launch.quitReply(true) == false)
        #expect(timers.live.isEmpty)
    }

    /// A second terminate during the wait keeps the first one's
    /// cancellation, and the idle quit doesn't fire over a pending one; the
    /// cancelled reply schedules the idle quit again, so a windowless
    /// minivu never stays running for good.
    @Test func reentrantQuitKeepsTheCancellation() {
        let (launch, timers, events) = make()
        launch.launchFinished(windowRequested: false)
        launch.actionBegan()
        launch.actionEnded()
        timers.fire()
        launch.quitWaits()
        launch.actionBegan()
        launch.actionEnded()
        launch.quitWaits()
        timers.fire()
        #expect(events.log == ["hide", "quit"])
        #expect(launch.quitReply(true) == false)
        #expect(timers.live == [IntentLaunch.idleGrace])
        timers.fire()
        #expect(events.log == ["hide", "quit", "quit"])
    }

    /// Any running action makes ⌘Q wait (`.terminateLater`) instead of
    /// quitting at once.
    @Test func runningActionMakesQuitWait() {
        func wait(actions: Int) -> Bool {
            AppDelegate.quitMustWait(hasEdits: false, marksMayBePending: false, pendingWrites: 0,
                                     transferActive: false, renamesRunning: 0, actionsRunning: actions)
        }
        #expect(wait(actions: 0) == false)
        #expect(wait(actions: 1))
    }

    /// ⌘Q while an action runs waits for it rather than cutting it off.
    @Test func quitWaitsForARunningAction() async {
        let (launch, _, _) = make()
        launch.launchFinished(windowRequested: true)
        launch.actionBegan()
        launch.quitWaits()
        #expect(launch.running == 1)
        let waited = Task { await launch.waitUntilNoActions(); return launch.running }
        await Task.yield()
        launch.actionEnded()
        #expect(await waited.value == 0)
        #expect(launch.quitReply(true))
        // Still running at reply time: no quit.
        launch.actionBegan()
        launch.quitWaits()
        #expect(launch.quitReply(true) == false)
        launch.actionEnded()
        await launch.waitUntilNoActions()   // returns at once
    }

    /// The launch log names the event and its parameter keywords only:
    /// never an open-documents event's file paths.
    @Test func launchEventLogShowsNoValues() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenDocuments),
                                           targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        let list = NSAppleEventDescriptor.list()
        list.insert(NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: "/Users/someone/Pictures/secret.jpg")), at: 0)
        event.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        let text = AppDelegate.describe(event)
        #expect(text == "aevt/odoc [----]")
        #expect(AppDelegate.describe(nil) == "none")
        #expect(AppDelegate.fourCharCode(0x0001_0203) == "0x00010203")
    }

    @Test func gracePeriods() {
        #expect(IntentLaunch.decisionWindow <= .milliseconds(300))
        #expect(IntentLaunch.idleGrace >= .seconds(30) && IntentLaunch.idleGrace <= .seconds(60))
    }
}
