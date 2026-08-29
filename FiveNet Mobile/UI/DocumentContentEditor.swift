import SwiftUI
import SwiftProtobuf
import Observation

/// Inline-Editor für den Inhalt eines Dokuments. Anders als ein reiner
/// Text-Editor arbeitet er blockbasiert auf dem originalen Tiptap-JSON:
/// - Absätze und Überschriften (nur Text-Kinder) sind editierbare Felder.
/// - Alle anderen Blöcke (Bilder, Listen, Checkboxen, Zitate, Code, Trennlinien,
///   Absätze mit eingebetteten Bildern) werden unverändert gerendert und bleiben
///   beim Speichern byte-identisch erhalten.
/// - Nur in tatsächlich editierten Absätzen werden Inline-Markierungen (fett,
///   kursiv, Links …) zu Klartext; unveränderte Blöcke verlieren nichts.
@Observable
final class DocumentContentEditorModel {
    let supportsEditing: Bool
    private let originalDoc: Google_Protobuf_Struct?
    var rows: [DocumentEditorRow] = []

    init(content: Resources_Common_Content_Content) {
        guard content.hasTiptapJson else {
            supportsEditing = false
            originalDoc = nil
            return
        }
        let doc = content.tiptapJson
        originalDoc = doc
        supportsEditing = true
        rows = Self.buildRows(from: doc)
    }

    /// Übernimmt den vorhandenen Inhalt eines Dokuments, das KEIN Tiptap-JSON
    /// hat (z. B. Template-Dokumente mit `ContentType = HTML`), als editierbare
    /// Zeilen. Der Inhalt wird blockweise in einen Tiptap-Doc konvertiert
    /// (Web-Muster `Editor.vue`: `tiptapToContent` — der Server speichert
    /// nach einem Update ohnehin immer Tiptap-JSON), damit vorhandener Inhalt
    /// erhalten bleibt statt geleert zu werden.
    init(converting content: Resources_Common_Content_Content) {
        let blocks = WikiContent.blocks(for: content)
        guard !blocks.isEmpty else {
            var doc = Google_Protobuf_Struct()
            doc.fields["type"] = .with { $0.stringValue = "doc" }
            originalDoc = doc
            supportsEditing = true
            rows = [Self.row(for: Self.node(for: .paragraph))]
            return
        }
        var doc = Google_Protobuf_Struct()
        doc.fields["type"] = .with { $0.stringValue = "doc" }
        var contentValues: [Google_Protobuf_Value] = []
        for block in blocks {
            contentValues.append(.with { $0.structValue = Self.tiptapNode(from: block) })
        }
        doc.fields["content"] = .with { $0.listValue = .with { $0.values = contentValues } }
        originalDoc = doc
        supportsEditing = true
        rows = Self.buildRows(from: doc)
    }

    /// Baut einen Tiptap-JSON-Knoten aus einem `WikiBlock` (Gegenstück zu
    /// `WikiContent.blocks(for:)` — ein Rundweg HTML ↔ Tiptap ist damit möglich).
    private static func tiptapNode(from block: WikiBlock) -> Google_Protobuf_Struct {
        func inlineContent(_ inline: [WikiInline]) -> Google_Protobuf_Value {
            var values: [Google_Protobuf_Value] = []
            for item in inline {
                values.append(.with { $0.structValue = inlineNode(item) })
            }
            return .with { $0.listValue = .with { $0.values = values } }
        }
        func wrap(_ inline: [WikiInline]) -> Google_Protobuf_Struct {
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "paragraph" }
            node.fields["content"] = inlineContent(inline)
            return node
        }

        switch block {
        case .paragraph(let inline):
            return wrap(inline)
        case .heading(let level, let inline):
            var node = wrap(inline)
            node.fields["type"] = .with { $0.stringValue = "heading" }
            var attrs = Google_Protobuf_Struct()
            attrs.fields["level"] = .with { $0.numberValue = Double(min(max(level, 1), 6)) }
            node.fields["attrs"] = .with { $0.structValue = attrs }
            return node
        case .bulletList(let items), .orderedList(_, let items), .taskList(let items):
            let isTask = block.isTaskList
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = block.listType }
            if case .orderedList(let start, _) = block {
                var attrs = Google_Protobuf_Struct()
                attrs.fields["start"] = .with { $0.numberValue = Double(start) }
                node.fields["attrs"] = .with { $0.structValue = attrs }
            }
            var itemValues: [Google_Protobuf_Value] = []
            for item in items {
                var itemNode = Google_Protobuf_Struct()
                itemNode.fields["type"] = .with { $0.stringValue = isTask ? "taskItem" : "listItem" }
                if isTask {
                    var attrs = Google_Protobuf_Struct()
                    attrs.fields["checked"] = .with { $0.boolValue = item.isChecked }
                    itemNode.fields["attrs"] = .with { $0.structValue = attrs }
                }
                var itemContent: [Google_Protobuf_Value] = []
                for child in item.blocks {
                    itemContent.append(.with { $0.structValue = tiptapNode(from: child) })
                }
                itemNode.fields["content"] = .with { $0.listValue = .with { $0.values = itemContent } }
                itemValues.append(.with { $0.structValue = itemNode })
            }
            node.fields["content"] = .with { $0.listValue = .with { $0.values = itemValues } }
            return node
        case .codeBlock(let text):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "codeBlock" }
            var textNode = Google_Protobuf_Struct()
            textNode.fields["type"] = .with { $0.stringValue = "text" }
            textNode.fields["text"] = .with { $0.stringValue = text }
            node.fields["content"] = .with { $0.listValue = .with {
                $0.values = [.with { $0.structValue = textNode }]
            } }
            return node
        case .quote(let blocks):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "blockquote" }
            var content: [Google_Protobuf_Value] = []
            for child in blocks {
                content.append(.with { $0.structValue = tiptapNode(from: child) })
            }
            node.fields["content"] = .with { $0.listValue = .with { $0.values = content } }
            return node
        case .rule:
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "horizontalRule" }
            return node
        case .image(let url, let alt):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "image" }
            var attrs = Google_Protobuf_Struct()
            attrs.fields["src"] = .with { $0.stringValue = url ?? "" }
            attrs.fields["alt"] = .with { $0.stringValue = alt }
            node.fields["attrs"] = .with { $0.structValue = attrs }
            return node
        case .table(let table):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "table" }
            var rowValues: [Google_Protobuf_Value] = []
            for row in table.rows {
                var rowNode = Google_Protobuf_Struct()
                rowNode.fields["type"] = .with { $0.stringValue = "tableRow" }
                var cellValues: [Google_Protobuf_Value] = []
                for cell in row {
                    var cellNode = Google_Protobuf_Struct()
                    cellNode.fields["type"] = .with { $0.stringValue = cell.isHeader ? "tableHeader" : "tableCell" }
                    var cellContent: [Google_Protobuf_Value] = []
                    for child in cell.blocks {
                        cellContent.append(.with { $0.structValue = tiptapNode(from: child) })
                    }
                    cellNode.fields["content"] = .with { $0.listValue = .with { $0.values = cellContent } }
                    cellValues.append(.with { $0.structValue = cellNode })
                }
                rowNode.fields["content"] = .with { $0.listValue = .with { $0.values = cellValues } }
                rowValues.append(.with { $0.structValue = rowNode })
            }
            node.fields["content"] = .with { $0.listValue = .with { $0.values = rowValues } }
            return node
        }
    }

    private static func inlineNode(_ inline: WikiInline) -> Google_Protobuf_Struct {
        switch inline {
        case .text(let text, let marks):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "text" }
            node.fields["text"] = .with { $0.stringValue = text }
            if !marks.isEmpty {
                var markValues: [Google_Protobuf_Value] = []
                for mark in marks {
                    markValues.append(.with { $0.structValue = markNode(mark) })
                }
                node.fields["marks"] = .with { $0.listValue = .with { $0.values = markValues } }
            }
            return node
        case .hardBreak:
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "hardBreak" }
            return node
        case .checkbox(let checked):
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "checkboxStandalone" }
            var attrs = Google_Protobuf_Struct()
            attrs.fields["checked"] = .with { $0.boolValue = checked }
            node.fields["attrs"] = .with { $0.structValue = attrs }
            return node
        }
    }

    private static func markNode(_ mark: WikiMark) -> Google_Protobuf_Struct {
        var node = Google_Protobuf_Struct()
        switch mark {
        case .bold:
            node.fields["type"] = .with { $0.stringValue = "bold" }
        case .italic:
            node.fields["type"] = .with { $0.stringValue = "italic" }
        case .underline:
            node.fields["type"] = .with { $0.stringValue = "underline" }
        case .strikethrough:
            node.fields["type"] = .with { $0.stringValue = "strike" }
        case .code:
            node.fields["type"] = .with { $0.stringValue = "code" }
        case .link(let url):
            node.fields["type"] = .with { $0.stringValue = "link" }
            var attrs = Google_Protobuf_Struct()
            attrs.fields["href"] = .with { $0.stringValue = url }
            node.fields["attrs"] = .with { $0.structValue = attrs }
        }
        return node
    }

    /// Startet einen leeren Editor (neues Dokument oder Dokument ohne
    /// bearbeitbaren Inhalt): ein einzelner leerer Absatz, der beim Speichern
    /// zum neuen Tiptap-Doc wird.
    init(empty: Void = ()) {
        supportsEditing = true
        var doc = Google_Protobuf_Struct()
        doc.fields["type"] = .with { $0.stringValue = "doc" }
        originalDoc = doc
        rows = [Self.row(for: Self.node(for: .paragraph))]
    }

    /// True, sobald in mindestens einem Absatz Text geändert wurde.
    var hasChanges: Bool {
        rows.contains { row in
            switch row.kind {
            case .paragraph, .heading:
                return row.text != row.originalText
            case .readOnly:
                return false
            }
        }
    }

    // MARK: - Block-Einfügen / -Löschen / -Verschieben

    /// Fügt einen neuen Tiptap-Block nach der angegebenen Zeile ein
    /// (`after` == nil → ans Ende).
    func insertBlock(_ kind: EditorInsertKind, after rowID: UUID? = nil) {
        let newRow = Self.row(for: Self.node(for: kind))
        if let rowID, let index = rows.firstIndex(where: { $0.id == rowID }) {
            rows.insert(newRow, at: index + 1)
        } else {
            rows.append(newRow)
        }
    }

    /// Entfernt eine Zeile komplett aus dem Dokument.
    func deleteRow(_ row: DocumentEditorRow) {
        rows.removeAll { $0.id == row.id }
    }

    /// Verschiebt eine Zeile um eine Position nach oben/unten.
    func moveRow(_ row: DocumentEditorRow, up: Bool) {
        guard let index = rows.firstIndex(where: { $0.id == row.id }) else { return }
        let target = up ? index - 1 : index + 1
        guard target >= rows.startIndex, target < rows.endIndex else { return }
        rows.swapAt(index, target)
    }

    private static func row(for node: Google_Protobuf_Struct) -> DocumentEditorRow {
        Self.buildRows(from: Self.wrappingDoc(node)).first
            ?? DocumentEditorRow(node: node, kind: .readOnly([]), text: "")
    }

    /// Baut den Tiptap-JSON-Knoten für einen einfügbaren Block.
    private static func node(for kind: EditorInsertKind) -> Google_Protobuf_Struct {
        func textNode(_ text: String = "") -> Google_Protobuf_Struct {
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "text" }
            node.fields["text"] = .with { $0.stringValue = text }
            return node
        }

        func paragraphNode() -> Google_Protobuf_Struct {
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "paragraph" }
            node.fields["content"] = .with { $0.listValue = .with {
                $0.values = [Google_Protobuf_Value.with { $0.structValue = textNode() }]
            } }
            return node
        }

        func listNode(_ type: String, checked: Bool? = nil) -> Google_Protobuf_Struct {
            var item = Google_Protobuf_Struct()
            item.fields["type"] = .with { $0.stringValue = type == "taskList" ? "taskItem" : "listItem" }
            if let checked {
                item.fields["attrs"] = .with { $0.structValue = { () -> Google_Protobuf_Struct in
                    var attrs = Google_Protobuf_Struct()
                    attrs.fields["checked"] = .with { $0.boolValue = checked }
                    return attrs
                }() }
            }
            item.fields["content"] = .with { $0.listValue = .with {
                $0.values = [Google_Protobuf_Value.with { $0.structValue = paragraphNode() }]
            } }

            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = type }
            node.fields["content"] = .with { $0.listValue = .with {
                $0.values = [Google_Protobuf_Value.with { $0.structValue = item }]
            } }
            return node
        }

        switch kind {
        case .paragraph:
            return paragraphNode()
        case .heading(let level):
            var node = paragraphNode()
            node.fields["type"] = .with { $0.stringValue = "heading" }
            var attrs = Google_Protobuf_Struct()
            attrs.fields["level"] = .with { $0.numberValue = Double(min(max(level, 1), 6)) }
            node.fields["attrs"] = .with { $0.structValue = attrs }
            return node
        case .bulletList:
            return listNode("bulletList")
        case .orderedList:
            return listNode("orderedList")
        case .taskList:
            return listNode("taskList", checked: false)
        case .blockquote:
            var node = paragraphNode()
            node.fields["type"] = .with { $0.stringValue = "blockquote" }
            return node
        case .codeBlock:
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "codeBlock" }
            node.fields["content"] = .with { $0.listValue = .with {
                $0.values = [Google_Protobuf_Value.with { $0.structValue = textNode() }]
            } }
            return node
        case .horizontalRule:
            var node = Google_Protobuf_Struct()
            node.fields["type"] = .with { $0.stringValue = "horizontalRule" }
            return node
        }
    }

    /// Baut das (veränderte) Dokument aus den bearbeiteten Zeilen wieder auf.
    /// Unveränderte Zeilen tragen ihren Original-Knoten; nur editierten
    /// Absätzen/Überschriften wird ein einzelner Text-Knoten zugewiesen.
    func buildContent() -> Resources_Common_Content_Content {
        var content = Resources_Common_Content_Content()
        content.contentType = .tiptapJson
        guard let originalDoc else { return content }

        var doc = Google_Protobuf_Struct()
        for (key, value) in originalDoc.fields where key != "content" {
            doc.fields[key] = value
        }
        var values: [Google_Protobuf_Value] = []
        for row in rows {
            let node: Google_Protobuf_Struct
            switch row.kind {
            case .paragraph, .heading:
                node = (row.text != row.originalText)
                    ? Self.rebuiltNode(from: row.originalNode, text: row.text)
                    : row.originalNode
            case .readOnly:
                node = row.originalNode
            }
            values.append(.with { $0.structValue = node })
        }
        if !values.isEmpty {
            doc.fields["content"] = .with { $0.listValue = .with { $0.values = values } }
        }
        content.tiptapJson = doc
        return content
    }

    // MARK: - Row building

    private static func buildRows(from doc: Google_Protobuf_Struct) -> [DocumentEditorRow] {
        guard let values = doc.fields["content"]?.listValue.values else { return [] }
        return values.compactMap { value -> DocumentEditorRow? in
            guard case .structValue(let node)? = value.kind else { return nil }
            let type = node.fields["type"]?.stringValue ?? ""
            let children = node.fields["content"]?.listValue.values ?? []
            let childStructs = children.compactMap { child -> Google_Protobuf_Struct? in
                guard case .structValue(let childStruct)? = child.kind else { return nil }
                return childStruct
            }
            let onlyText = childStructs.allSatisfy { child in
                let childType = child.fields["type"]?.stringValue ?? ""
                return childType == "text" || childType == "hardBreak"
            }
            if (type == "paragraph" || type == "heading") && onlyText {
                if type == "heading" {
                    let level = Int(node.fields["attrs"]?.structValue.fields["level"]?.numberValue ?? 1)
                    return DocumentEditorRow(
                        node: node,
                        kind: .heading(level: min(max(level, 1), 6)),
                        text: plainText(node: node)
                    )
                }
                return DocumentEditorRow(node: node, kind: .paragraph, text: plainText(node: node))
            }
            return DocumentEditorRow(node: node, kind: .readOnly(block(for: node)), text: "")
        }
    }

    /// Renders a single Tiptap node to blocks by wrapping it in a temporary doc.
    private static func block(for node: Google_Protobuf_Struct) -> [WikiBlock] {
        var temp = Resources_Common_Content_Content()
        temp.contentType = .tiptapJson
        temp.tiptapJson = wrappingDoc(node)
        return WikiContent.blocks(for: temp)
    }

    private static func wrappingDoc(_ node: Google_Protobuf_Struct) -> Google_Protobuf_Struct {
        var doc = Google_Protobuf_Struct()
        doc.fields["type"] = .with { $0.stringValue = "doc" }
        doc.fields["content"] = .with { $0.listValue = .with {
            $0.values = [Google_Protobuf_Value.with { $0.structValue = node }]
        } }
        return doc
    }

    /// Concatenates the visible text of a paragraph/heading node (Tiptap JSON).
    private static func plainText(node: Google_Protobuf_Struct) -> String {
        let type = node.fields["type"]?.stringValue ?? ""
        var parts: [String] = []
        if type == "text", let text = node.fields["text"]?.stringValue {
            parts.append(text)
        }
        if let children = node.fields["content"]?.listValue.values {
            for child in children {
                guard case .structValue(let childStruct)? = child.kind else { continue }
                let value = plainText(node: childStruct)
                if !value.isEmpty { parts.append(value) }
            }
        }
        var result = parts.joined()
        if type == "hardBreak" {
            result += "\n"
        }
        return result
    }

    /// Rebuilds a paragraph/heading node keeping type + attrs (z. B. heading
    /// level) but replacing the content with a single text node.
    private static func rebuiltNode(from original: Google_Protobuf_Struct, text: String) -> Google_Protobuf_Struct {
        var node = Google_Protobuf_Struct()
        for (key, value) in original.fields where key == "type" || key == "attrs" {
            node.fields[key] = value
        }
        var textNode = Google_Protobuf_Struct()
        textNode.fields["type"] = .with { $0.stringValue = "text" }
        textNode.fields["text"] = .with { $0.stringValue = text }
        node.fields["content"] = .with { $0.listValue = .with {
            $0.values = [Google_Protobuf_Value.with { $0.structValue = textNode }]
        } }
        return node
    }
}

enum DocumentEditorKind {
    case paragraph
    case heading(level: Int)
    case readOnly([WikiBlock])
}

/// Block-Typen, die über die Editor-Toolbar neu eingefügt werden können
/// (Spiegelung der Block-Ebene des Web `TiptapToolbar.vue`).
enum EditorInsertKind: Identifiable, CaseIterable {
    case paragraph
    case heading(level: Int)
    case bulletList
    case orderedList
    case taskList
    case blockquote
    case codeBlock
    case horizontalRule

    var id: String {
        switch self {
        case .paragraph: return "paragraph"
        case .heading(let level): return "heading-\(level)"
        case .bulletList: return "bulletList"
        case .orderedList: return "orderedList"
        case .taskList: return "taskList"
        case .blockquote: return "blockquote"
        case .codeBlock: return "codeBlock"
        case .horizontalRule: return "horizontalRule"
        }
    }

    var label: String {
        switch self {
        case .paragraph: return "Absatz"
        case .heading(let level): return "Überschrift \(level)"
        case .bulletList: return "Aufzählung"
        case .orderedList: return "Nummerierte Liste"
        case .taskList: return "Checkliste"
        case .blockquote: return "Zitat"
        case .codeBlock: return "Code-Block"
        case .horizontalRule: return "Trennlinie"
        }
    }

    var systemImage: String {
        switch self {
        case .paragraph: return "paragraphsign"
        case .heading(let level): return "\(level).circle"
        case .bulletList: return "list.bullet"
        case .orderedList: return "list.number"
        case .taskList: return "checklist"
        case .blockquote: return "quote.opening"
        case .codeBlock: return "chevron.left.forwardslash.chevron.right"
        case .horizontalRule: return "minus"
        }
    }

    static var allCases: [EditorInsertKind] {
        [.paragraph, .heading(level: 1), .heading(level: 2), .heading(level: 3), .heading(level: 4), .bulletList, .orderedList, .taskList, .blockquote, .codeBlock, .horizontalRule]
    }
}

private extension WikiBlock {
    var isTaskList: Bool {
        if case .taskList = self { return true }
        return false
    }

    var listType: String {
        switch self {
        case .bulletList: return "bulletList"
        case .orderedList: return "orderedList"
        case .taskList: return "taskList"
        default: return ""
        }
    }
}

/// A single row of the content editor. Reference type so SwiftUI bindings
/// (`@Bindable`) observe text edits on the underlying @Observable object.
@Observable
final class DocumentEditorRow: Identifiable {
    let id = UUID()
    let originalNode: Google_Protobuf_Struct
    let kind: DocumentEditorKind
    var text: String
    let originalText: String

    init(node: Google_Protobuf_Struct, kind: DocumentEditorKind, text: String) {
        self.originalNode = node
        self.kind = kind
        self.text = text
        self.originalText = text
    }
}

/// Editable representation of a document's content in the detail view.
struct DocumentContentEditorView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: DocumentContentEditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            toolbar

            LazyVStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                ForEach(model.rows) { row in
                    rowView(row)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Toolbar zum Einfügen neuer Blöcke (an das Ende des Dokuments).
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(EditorInsertKind.allCases) { kind in
                    Button {
                        model.insertBlock(kind)
                    } label: {
                        Label(kind.label, systemImage: kind.systemImage)
                            .font(.caption.weight(.medium))
                            .labelStyle(.titleAndIcon)
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .background(
                                Theme.Palette.surface,
                                in: Capsule()
                            )
                            .overlay(
                                Capsule()
                                    .strokeBorder(Color(.separator).opacity(0.4))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
        }
    }

    @ViewBuilder
    private func rowView(_ row: DocumentEditorRow) -> some View {
        @Bindable var row = row
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            switch row.kind {
            case .paragraph:
                TextField("Absatz…", text: $row.text, axis: .vertical)
                    .lineLimit(1...8)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .heading(let level):
                TextField("Überschrift…", text: $row.text, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.system(size: Self.headingSize(for: level), weight: .bold))
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .readOnly(let blocks):
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(blocks.indices, id: \.self) { index in
                        WikiBlockView(block: blocks[index], baseURL: appState.client?.baseURL)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            rowMenu(row)
        }
    }

    /// Kontextmenü je Zeile: Block danach einfügen, verschieben, löschen.
    private func rowMenu(_ row: DocumentEditorRow) -> some View {
        Menu {
            ForEach(EditorInsertKind.allCases) { kind in
                Button {
                    model.insertBlock(kind, after: row.id)
                } label: {
                    Label(kind.label, systemImage: kind.systemImage)
                }
            }
            Divider()
            Button {
                model.moveRow(row, up: true)
            } label: {
                Label("Nach oben", systemImage: "chevron.up")
            }
            .disabled(model.rows.first?.id == row.id)
            Button {
                model.moveRow(row, up: false)
            } label: {
                Label("Nach unten", systemImage: "chevron.down")
            }
            .disabled(model.rows.last?.id == row.id)
            Divider()
            Button(role: .destructive) {
                model.deleteRow(row)
            } label: {
                Label("Block löschen", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private static func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 24
        case 2: return 21
        case 3: return 19
        case 4: return 17
        default: return 16
        }
    }
}
