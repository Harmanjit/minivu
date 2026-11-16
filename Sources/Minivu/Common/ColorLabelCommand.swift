import AppKit
import MinivuCore
import os

/// Image > Label: None, Red, Orange, Yellow, Green, Blue, Purple, Gray
/// (⌥⌘0–⌥⌘7), in the browser for its selection, in the viewer for its
/// image and in the compare window for the focused pane (G4).
///
/// A label is the file's standard Finder colour tag, the Mac's own colour
/// label, so Finder, Spotlight and Smart Folders see it, and the browser's
/// dots and Finder tag filter show it. Choosing one replaces whichever
/// standard colour tag the file had and keeps every other tag; None
/// removes the colour tag. While "Write ratings into files (XMP)" is on,
/// the label also goes into the file as `xmp:Label` (`MarksFileWriter`).
@MainActor enum ColorLabelCommand {
    /// The Label submenu, its items tagged with `ColorLabel` raw values.
    /// The menu bar's has the shortcuts; the grid's context menu doesn't.
    static func menu(withShortcuts: Bool) -> NSMenu {
        let menu = NSMenu(title: localized(.init("Label",
                                                 comment: "Noun: submenu of colour labels (Finder's colour tags)")))
        for label in ColorLabel.allCases {
            let item = NSMenuItem(title: label.localizedName, action: .setColorLabel,
                                  keyEquivalent: withShortcuts ? String(label.rawValue) : "")
            item.keyEquivalentModifierMask = withShortcuts ? [.command, .option] : []
            item.tag = label.rawValue
            item.image = swatch(label)
            menu.addItem(item)
        }
        return menu
    }

    /// A dot in the label's colour, as Finder draws its tags; a hollow ring
    /// for None. The item's title says the colour, which VoiceOver reads.
    static func swatch(_ label: ColorLabel) -> NSImage {
        let color = FinderTag(name: label.name, colorIndex: label.finderColorIndex).color
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 1.5, dy: 1.5))
            if let color {
                color.setFill()
                circle.fill()
            } else {
                NSColor.secondaryLabelColor.setStroke()
                circle.lineWidth = 1
                circle.stroke()
            }
            return true
        }
        image.accessibilityDescription = label.localizedName
        return image
    }

    /// The label a menu item stands for.
    static func label(of sender: Any?) -> ColorLabel? {
        ((sender as? NSMenuItem)?.tag ?? (sender as? NSControl)?.tag).flatMap(ColorLabel.init(rawValue:))
    }

    /// Finder's names for its standard colour tags, by label number. They
    /// follow the system's language and any renaming in Finder's settings,
    /// and are what Finder itself writes for the tag.
    /// Read once a launch: menu validation asks for every item.
    static var standardNames: [Int: String] {
        if let cachedNames { return cachedNames }
        var names: [Int: String] = [:]
        for (index, name) in NSWorkspace.shared.fileLabels.enumerated() where (1...7).contains(index) && !name.isEmpty {
            names[index] = name
        }
        let result = names.count == 7 ? names : FinderTags.englishColorNames
        cachedNames = result
        return result
    }
    private static var cachedNames: [Int: String]?

    /// The colour label among a file's Finder tags: the colour of its first
    /// standard colour tag (named as Finder's own, or in English), or None.
    /// A tag of another name keeps its colour out of this: "Project" in
    /// blue is the user's own tag, not a label.
    nonisolated static func label(of tags: [FinderTag], standardNames: [Int: String]) -> ColorLabel {
        var byName: [String: Int] = ["grey": 1]
        for (index, name) in Array(FinderTags.englishColorNames) + Array(standardNames) {
            byName[name.lowercased()] = index
        }
        for tag in tags {
            guard let standard = byName[tag.name.lowercased()] else { continue }
            let index = (1...7).contains(tag.colorIndex) ? tag.colorIndex : standard
            return ColorLabel(finderColorIndex: index) ?? .none
        }
        return .none
    }

    /// The label every file has, for the menu's checkmark; nil when they
    /// differ or there are none.
    nonisolated static func sharedLabel(_ tagsOfEachFile: [[FinderTag]], standardNames: [Int: String]) -> ColorLabel? {
        let labels = Set(tagsOfEachFile.map { label(of: $0, standardNames: standardNames) })
        return labels.count == 1 ? labels.first : nil
    }

    /// Ticks the item of the label every file shares.
    static func showState(_ menuItem: NSMenuItem, shared: ColorLabel?) {
        menuItem.state = shared?.rawValue == menuItem.tag ? .on : .off
    }

    /// The label writes under way, for tests to await.
    private(set) static var work: Task<Void, Never>?

    /// Gives `urls` the label: in line behind every other write to them
    /// (an image write keeps the file's extended attributes, so a tag set
    /// while one is under way could be lost), off the main thread. Then
    /// hands the label to `writer` for the XMP copy, and calls back with
    /// the files that took it, for the views to show. A file that couldn't
    /// take it (permissions) is logged and beeped at.
    static func setLabel(_ label: ColorLabel, for urls: [URL], writer: MarksFileWriter = .shared,
                         completion: @escaping ([URL]) -> Void = { _ in }) {
        guard !urls.isEmpty else { return }
        work = Task {
            let result = await write(label, for: urls, writer: writer)
            if !result.failed.isEmpty { NSSound.beep() }
            completion(result.done)
        }
    }

    /// `setLabel`'s work, awaited and silent: the files that took the label
    /// and those that didn't, for a caller that reports failures itself (a
    /// Shortcuts action, which has no window to beep at).
    static func write(_ label: ColorLabel, for urls: [URL],
                      writer: MarksFileWriter = .shared) async -> (done: [URL], failed: [URL]) {
        guard !urls.isEmpty else { return ([], []) }
        let names = standardNames
        let job = FileWriteQueue.shared.enqueue(touching: urls) {
            await BlockingWork.run { () -> (done: [URL], failed: [URL]) in
                var done: [URL] = [], failed: [URL] = []
                for url in urls {
                    do {
                        try FinderTags.setColorLabel(label, for: url, standardNames: names)
                        done.append(url)
                    } catch {
                        failed.append(url)
                        labelLog.error("Labelling \(url.lastPathComponent, privacy: .private) failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                return (done, failed)
            }
        }
        let result: (done: [URL], failed: [URL]) = (try? await job.value)?.value ?? ([], urls)
        writer.labelChanged(label, of: result.done)
        return result
    }
}

nonisolated private let labelLog = Logger(subsystem: "com.minivu.app", category: "labels")
