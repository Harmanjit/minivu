import AppKit
import MinivuCore

/// Prints pictures with a page layout: the system print panel as a sheet,
/// with minivu's layout accessory and the panel's live preview.
enum PrintPresenter {
    /// Operations under way. A print outlives the command that started it
    /// (the job runs on after the panel closes), so something must hold it.
    private(set) static var sessions: [PrintSession] = []

    /// Makes the print operation for `items`, without running it.
    static func makeSession(items: [LayoutItem], title: String, store: PrintLayoutStore = PrintLayoutStore(),
                            printInfo: NSPrintInfo = .shared) -> PrintSession {
        PrintSession(items: items, title: title, store: store, printInfo: printInfo)
    }

    static func present(items: [LayoutItem], title: String, on window: NSWindow,
                        store: PrintLayoutStore = PrintLayoutStore()) {
        guard !items.isEmpty else { return }
        let session = makeSession(items: items, title: title, store: store)
        sessions.append(session)
        session.run(on: window) { finished in
            sessions.removeAll { $0 === finished }
        }
    }

    /// The window title of a print: the one picture's name, or "12 Pictures".
    nonisolated static func jobTitle(for items: [LayoutItem]) -> String {
        items.count == 1 ? items[0].name : "\(items.count) Pictures"
    }
}

/// One print operation and what it needs until it finishes.
final class PrintSession: NSObject {
    let job: PrintJob
    let view: PrintPageView
    let accessory: PrintAccessoryController
    let operation: NSPrintOperation
    private var completion: ((PrintSession) -> Void)?

    init(items: [LayoutItem], title: String, store: PrintLayoutStore, printInfo shared: NSPrintInfo) {
        // A copy of the shared print info, so Page Setup's paper, scale and
        // printer apply, with its margins cleared: the layout keeps its own
        // margins, and each page rectangle is the whole sheet.
        let info = (shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.topMargin = 0
        info.bottomMargin = 0
        info.leftMargin = 0
        info.rightMargin = 0
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        job = PrintJob(items: items, settings: store.settings, paper: PrintPaper(printInfo: info))
        view = PrintPageView(job: job)
        accessory = PrintAccessoryController(job: job, store: store)
        operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        // The job decodes every picture at the printer's resolution; on a
        // thread of its own the app stays usable meanwhile.
        operation.canSpawnSeparateThread = true
        let panel = operation.printPanel
        panel.options.formUnion([.showsCopies, .showsPageRange, .showsPaperSize, .showsOrientation, .showsScaling,
                                 .showsPreview])
        panel.addAccessoryController(accessory)
        super.init()
    }

    func run(on window: NSWindow, completion: @escaping (PrintSession) -> Void) {
        self.completion = completion
        operation.runModal(for: window, delegate: self,
                           didRun: #selector(printOperationDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    /// AppKit calls this when the job is done (or the panel was cancelled),
    /// possibly from the print thread; the rest happens on the main thread.
    @objc nonisolated func printOperationDidRun(_ operation: NSPrintOperation, success: Bool,
                                                contextInfo: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finish(success: success) }
        }
    }

    private func finish(success: Bool) {
        if success {
            // The paper and printer chosen in the panel become Page Setup's,
            // as in other Mac apps, with the shared margins left as they were.
            let shared = NSPrintInfo.shared
            if let chosen = operation.printInfo.copy() as? NSPrintInfo {
                chosen.topMargin = shared.topMargin
                chosen.bottomMargin = shared.bottomMargin
                chosen.leftMargin = shared.leftMargin
                chosen.rightMargin = shared.rightMargin
                chosen.isHorizontallyCentered = shared.isHorizontallyCentered
                chosen.isVerticallyCentered = shared.isVerticallyCentered
                NSPrintInfo.shared = chosen
            }
        }
        completion?(self)
        completion = nil
    }
}
