import Foundation
import CoreGraphics
import Observation
import MinivuRender

/// The drawing tool's toolbar: the selection arrow and one tool per kind of
/// object. Raw values are the tags `drawAnnotations(_:)` senders carry.
nonisolated enum AnnotationToolKind: Int, CaseIterable, Identifiable, Sendable {
    case select = 0, text, line, arrow, highlight, rectangle, oval, callout

    var id: Int { rawValue }

    /// The kind of object the tool draws; nil for the selection arrow.
    var objectKind: Annotation.Kind? {
        switch self {
        case .select: nil
        case .text: .text
        case .line: .line
        case .arrow: .arrow
        case .highlight: .highlight
        case .rectangle: .rectangle
        case .oval: .oval
        case .callout: .callout
        }
    }

    var title: String { objectKind?.title ?? "Select" }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .text: "textformat"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .highlight: "highlighter"
        case .rectangle: "rectangle"
        case .oval: "oval"
        case .callout: "text.bubble"
        }
    }
}

/// The drawing tool: the objects being edited, the selection, the style for
/// the next object, and how all of it reaches the document (DESIGN.md 4.7).
///
/// **Preview.** The working set shows on the canvas as the document's
/// preview, `.annotations(objects)`, rendered by the edit graph exactly as it
/// will be saved. Objects being dragged or typed in (`liveIDs`) are left out
/// of it and drawn by the overlay instead, so a drag never waits for a
/// render: the preview changes when a drag starts and ends, and when a
/// property changes, coalesced to one update per turn of the run loop.
///
/// **Undo.** Changes inside the tool have their own undo stack, so taking back
/// the last arrow doesn't throw the whole drawing away: ⌘Z and ⇧⌘Z while the
/// overlay has the keyboard (the Edit menu's Undo item, as for every tool,
/// cancels the tool when chosen with the mouse). Apply commits one
/// `.annotations` operation, one step on the document's history ("Undo
/// Drawing"); Cancel commits nothing.
///
/// **Editing a drawing again.** Drawings stay editable until the image is
/// saved or another edit is stacked on them: when the tool opens on a
/// document whose *last* committed operation is `.annotations`, that
/// operation is undone and its objects become the working set (shown as the
/// preview in the same turn, so nothing flickers). Apply then commits the
/// edited set in its place, which drops the undone step from redo. Cancel
/// redoes it, which leaves the document exactly as it was. Apply with every
/// object deleted commits nothing, and the old drawing stays available to
/// Redo. Once another edit is on top (a crop, say) the drawing stays in the
/// list as vectors, still rendered sharply at every size, but the tool no
/// longer opens it: a new drawing goes on top. After a save the drawing is
/// in the file's pixels, and editing starts over from them.
@Observable final class AnnotationToolState: EditToolState {
    /// The output image's full-resolution size, which lengths refer to.
    let imageSize: CGSize

    /// The working set, bottom to top. Not observed: a drag changes it on
    /// every mouse event, and the inspector only needs `inspected`.
    @ObservationIgnored private(set) var objects: [Annotation]

    var tool: AnnotationToolKind {
        didSet {
            guard tool != oldValue else { return }
            endTextEditing()
            if let kind = tool.objectKind, let selected, selected.kind != kind { select(nil) }
            refreshInspected()
            onChange?()
        }
    }

    @ObservationIgnored private(set) var selectedID: UUID?
    @ObservationIgnored private(set) var editingID: UUID?
    /// Objects the overlay draws itself, left out of the document's preview.
    @ObservationIgnored private(set) var liveIDs: Set<UUID> = []
    /// Style for the next object of each kind.
    @ObservationIgnored private(set) var templates: [Annotation.Kind: Annotation]

    /// What the inspector shows: the selected object, or the next object's
    /// template for the current tool, with its geometry and text cleared so
    /// a drag doesn't redraw the inspector. Nil with nothing to style.
    private(set) var inspected: Annotation?
    /// Whether `inspected` is a selected object (rather than a template).
    private(set) var hasSelection = false

    /// For the overlay: after every change to objects, selection or editing.
    @ObservationIgnored var onChange: (() -> Void)?
    /// For the overlay: these objects stopped being live, so the canvas will
    /// show them once the preview renders.
    @ObservationIgnored var onLiveEnded: ((Set<UUID>) -> Void)?

    @ObservationIgnored private let document: EditDocument
    /// The objects the tool opened with (a drawing being edited again).
    @ObservationIgnored let original: [Annotation]
    @ObservationIgnored let isReEditing: Bool
    @ObservationIgnored private var isClosed = false
    @ObservationIgnored private var previewScheduled = false

    struct UndoStep {
        let name: String
        let objects: [Annotation]
        let selectedID: UUID?
    }

    @ObservationIgnored private var undoStack: [UndoStep] = []
    @ObservationIgnored private var redoStack: [UndoStep] = []
    @ObservationIgnored private var coalescing: (key: String, time: TimeInterval)?
    static let maximumUndoSteps = 100

    /// ⌘C within the tool, kept while the app runs so a drawing can be copied
    /// from one image to the next.
    static var clipboard: [Annotation] = []

    init(document: EditDocument, imageSize: CGSize, tool: AnnotationToolKind = .select) {
        self.document = document
        self.imageSize = imageSize
        self.tool = tool
        templates = Dictionary(uniqueKeysWithValues: Annotation.Kind.allCases.map { ($0, Annotation(kind: $0)) })
        if case .annotations(let existing)? = document.operations.last, document.canUndo {
            original = existing
            isReEditing = true
            objects = existing
            // Preview first, then undo: both in this turn, so the next render
            // shows the same picture it did.
            document.preview = .annotations(existing)
            document.undo()
        } else {
            original = []
            isReEditing = false
            objects = []
        }
        refreshInspected()
    }

    // MARK: - EditToolState

    var title: String { "Text and Shapes" }

    /// A drawing being edited again counts even unchanged: its operation is
    /// off the document while the tool is open, so closing without Apply
    /// must never be mistaken for having nothing to lose.
    var hasPendingChanges: Bool { isReEditing || !objects.isEmpty }

    var capturesKeyboard: Bool { editingID != nil }

    func apply() {
        endTextEditing()
        isClosed = true
        liveIDs = []
        document.apply(.annotations(objects))   // nothing recorded when empty; the preview clears either way
    }

    func cancel() {
        editingID = nil
        isClosed = true
        liveIDs = []
        document.preview = nil
        if isReEditing, document.canRedo { document.redo() }
    }

    func reset() {
        guard objects != original else { return }
        endTextEditing()
        recordUndo("Reset")
        objects = original
        selectedID = nil
        changed()
    }

    // MARK: - Reading

    func object(_ id: UUID) -> Annotation? {
        objects.first { $0.id == id }
    }

    var selected: Annotation? { selectedID.flatMap(object) }

    /// A new object of `kind` in the current style for it.
    func newObject(_ kind: Annotation.Kind) -> Annotation {
        var a = templates[kind] ?? Annotation(kind: kind)
        a.id = UUID()
        a.text = ""
        return a
    }

    // MARK: - Changing objects

    func select(_ id: UUID?) {
        if let editingID, editingID != id { endTextEditing() }
        guard selectedID != id else { return }
        selectedID = id.flatMap { object($0) != nil ? $0 : nil }
        refreshInspected()
        onChange?()
    }

    /// Adds `a` on top and selects it; `live` while a drag is still sizing it.
    func add(_ a: Annotation, live: Bool = false) {
        endTextEditing()
        recordUndo("Add \(a.kind.title)")
        objects.append(a)
        selectedID = a.id
        if live { liveIDs.insert(a.id) }
        changed()
    }

    /// Replaces the object with `a`'s id. Geometry changes from a drag don't
    /// record undo steps (the drag recorded one when it began).
    func replace(_ a: Annotation) {
        guard let index = objects.firstIndex(where: { $0.id == a.id }), objects[index] != a else { return }
        objects[index] = a
        changed()
    }

    /// A drag starts moving or reshaping `id`: the overlay draws it from now on.
    func beginLive(_ id: UUID) {
        guard object(id) != nil, !liveIDs.contains(id) else { return }
        liveIDs.insert(id)
        changed()
    }

    /// The drag is over: everything live but text being typed goes back to
    /// the rendered preview.
    func endLive() {
        let ended = liveIDs.subtracting(editingID.map { [$0] } ?? [])
        guard !ended.isEmpty else { return }
        liveIDs.subtract(ended)
        changed()
        onLiveEnded?(ended)
    }

    func deleteSelection() {
        guard let id = selectedID, let index = objects.firstIndex(where: { $0.id == id }) else { return }
        recordUndo("Delete \(objects[index].kind.title)")
        if editingID == id { editingID = nil }
        objects.remove(at: index)
        liveIDs.remove(id)
        selectedID = nil
        changed()
    }

    /// A copy of the selection, a little down and to the right, selected.
    func duplicateSelection() {
        guard let a = selected else { return }
        endTextEditing()
        var copy = AnnotationGeometry.moved(a, by: offsetForCopies, in: imageSize)
        copy.id = UUID()
        recordUndo("Duplicate \(a.kind.title)")
        objects.append(copy)
        selectedID = copy.id
        changed()
    }

    func copySelection() {
        guard let a = selected else { return }
        Self.clipboard = [a]
    }

    func cutSelection() {
        copySelection()
        deleteSelection()
    }

    /// The clipboard's objects on top, offset when their originals are still
    /// here, so a paste never hides exactly under what was copied.
    func paste() {
        guard !Self.clipboard.isEmpty else { return }
        endTextEditing()
        recordUndo("Paste")
        var last: UUID?
        for original in Self.clipboard {
            let clash = objects.contains { $0.frame == original.frame && $0.start == original.start && $0.kind == original.kind }
            var a = clash ? AnnotationGeometry.moved(original, by: offsetForCopies, in: imageSize) : original
            a.id = UUID()
            objects.append(a)
            last = a.id
        }
        selectedID = last
        changed()
    }

    /// Moves the selection by whole image pixels; repeated presses within a
    /// second are one undo step.
    func nudge(dx: CGFloat, dy: CGFloat) {
        guard let a = selected else { return }
        recordUndo("Move", coalescing: "nudge-\(a.id)")
        replace(AnnotationGeometry.moved(a, by: CGSize(width: dx, height: dy), in: imageSize))
    }

    /// Brings the selection to the front (top of the list) or sends it back.
    func arrangeSelection(toFront: Bool) {
        guard let id = selectedID, let index = objects.firstIndex(where: { $0.id == id }) else { return }
        guard toFront ? index < objects.count - 1 : index > 0 else { return }
        recordUndo(toFront ? "Bring to Front" : "Send to Back")
        let a = objects.remove(at: index)
        if toFront { objects.append(a) } else { objects.insert(a, at: 0) }
        changed()
    }

    private var offsetForCopies: CGSize {
        let step = max(min(imageSize.width, imageSize.height) * 0.02, 1)
        return CGSize(width: step, height: step)
    }

    // MARK: - Style

    /// Changes the selected object's style (and remembers it for the next
    /// object of that kind), or with nothing selected the style the current
    /// tool draws with. `name` names the undo step; a continuous change (a
    /// colour or a slider dragged) is one step.
    func updateStyle(_ name: String, _ body: (inout Annotation) -> Void) {
        if let id = selectedID, var a = object(id) {
            let before = a
            body(&a)
            guard a != before else { return }
            recordUndo(name, coalescing: "style-\(name)-\(id)")
            if a.kind.hasText, a.autoresizesHeight { fitHeight(&a) }
            var template = a
            template.text = ""
            templates[a.kind] = template
            replace(a)
        } else if let kind = tool.objectKind, var template = templates[kind] {
            body(&template)
            templates[kind] = template
            refreshInspected()
        }
    }

    // MARK: - Text

    func beginTextEditing(_ id: UUID) {
        guard let a = object(id), a.kind.hasText, editingID != id else { return }
        endTextEditing()
        recordUndo("Typing")
        selectedID = id
        editingID = id
        liveIDs.insert(id)
        changed()
    }

    func setText(_ text: String, of id: UUID) {
        guard var a = object(id), a.text != text else { return }
        a.text = text
        if a.autoresizesHeight { fitHeight(&a) }
        replace(a)
    }

    /// Ends typing. A text object left empty is removed (a callout keeps its
    /// bubble).
    func endTextEditing() {
        guard let id = editingID else { return }
        editingID = nil
        if let index = objects.firstIndex(where: { $0.id == id }), objects[index].kind == .text,
           objects[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            objects.remove(at: index)
            if selectedID == id { selectedID = nil }
            // Typing nothing into a new text box leaves no undo step behind:
            // neither the typing (which began on an empty box) nor the adding
            // of the box. Otherwise Undo would bring back an invisible, empty
            // box. Text that was there before and was all deleted keeps its
            // step, so Undo brings the text back.
            func hadNoText(_ step: UndoStep?) -> Bool {
                guard let step else { return false }
                return step.objects.first { $0.id == id }.map { $0.text.isEmpty } ?? true
            }
            if undoStack.last?.name == "Typing", hadNoText(undoStack.last) {
                undoStack.removeLast()
                if let last = undoStack.last, last.name.hasPrefix("Add "), !last.objects.contains(where: { $0.id == id }) {
                    undoStack.removeLast()
                }
            }
        }
        let wasLive = liveIDs.remove(id) != nil
        changed()
        if wasLive, object(id) != nil { onLiveEnded?([id]) }
    }

    /// Sets a text object's height to fit its text at its width.
    func fitHeight(_ a: inout Annotation) {
        guard a.kind.hasText else { return }
        let height = AnnotationRenderer.fittingHeight(for: a, in: imageSize)
        guard height.isFinite, height > 0 else { return }
        a.frame.size.height = CGFloat(height)
    }

    // MARK: - Undo within the tool

    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// Remembers the objects before a change. Changes sharing `key` within a
    /// second of each other are one step.
    func recordUndo(_ name: String, coalescing key: String? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { coalescing = key.map { ($0, now) } }
        if let key, let last = coalescing, last.key == key, now - last.time < 1 { return }
        undoStack.append(UndoStep(name: name, objects: objects, selectedID: selectedID))
        if undoStack.count > Self.maximumUndoSteps { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        endTextEditing()
        guard let step = undoStack.popLast() else { return }
        redoStack.append(UndoStep(name: step.name, objects: objects, selectedID: selectedID))
        restore(step)
    }

    func redo() {
        endTextEditing()
        guard let step = redoStack.popLast() else { return }
        undoStack.append(UndoStep(name: step.name, objects: objects, selectedID: selectedID))
        restore(step)
    }

    private func restore(_ step: UndoStep) {
        coalescing = nil
        objects = step.objects
        selectedID = step.selectedID.flatMap { id in objects.contains { $0.id == id } ? id : nil }
        liveIDs = []
        changed()
    }

    // MARK: - Preview

    /// After any change: the preview (coalesced), the inspector, the overlay.
    private func changed() {
        schedulePreview()
        refreshInspected()
        onChange?()
    }

    private func schedulePreview() {
        guard !previewScheduled, !isClosed else { return }
        previewScheduled = true
        DispatchQueue.main.async { [weak self] in self?.flushPreview() }
    }

    /// Puts the working set, less what the overlay is drawing, on the
    /// document as its preview. Normally run by the coalescing above.
    func flushPreview() {
        previewScheduled = false
        guard !isClosed else { return }
        let rendered = objects.filter { !liveIDs.contains($0.id) }
        let op: EditOperation? = rendered.isEmpty ? nil : .annotations(rendered)
        if document.preview != op { document.preview = op }
    }

    private func refreshInspected() {
        var shown: Annotation?
        if let a = selected {
            shown = a
        } else if let kind = tool.objectKind {
            shown = templates[kind]
        }
        if var s = shown {
            // Only the style: geometry and text change without the inspector.
            s.frame = .zero
            s.start = .zero
            s.end = .zero
            s.tailPoint = .zero
            s.rotation = 0
            s.text = ""
            shown = s
        }
        let selection = selected != nil
        if inspected != shown { inspected = shown }
        if hasSelection != selection { hasSelection = selection }
    }
}

/// Edit > Undo chosen from the menu (or ⌘Z with the keyboard elsewhere)
/// takes back one drawing step, as ⌘Z over the canvas does, rather than
/// closing the tool and dropping every object in it.
extension AnnotationToolState: EditToolSteps {
    var undoStepTitle: String? { undoName }
    var redoStepTitle: String? { redoName }

    func undoStep() -> Bool {
        guard undoName != nil else { return false }
        undo()
        return true
    }

    func redoStep() -> Bool {
        guard redoName != nil else { return false }
        redo()
        return true
    }
}
