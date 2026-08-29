import SwiftUI
import UIKit
import SwiftProtobuf

/// A single inline segment of wiki content with optional formatting marks.
enum WikiInline {
    case text(String, marks: [WikiMark])
    case hardBreak
    /// fivenet `CheckboxStandalone`-Node: inline Checkbox in einem Absatz
    /// (Web `tiptap/extensions/CheckboxStandalone.ts`, Node-Typ
    /// `checkboxStandalone`, Attribut `checked`).
    case checkbox(Bool)
}

enum WikiMark {
    case bold
    case italic
    case underline
    case strikethrough
    case code
    case link(url: String)
}

/// A block-level piece of wiki content.
enum WikiBlock {
    case paragraph([WikiInline])
    case heading(level: Int, [WikiInline])
    case bulletList([WikiListItem])
    case orderedList(start: Int, [WikiListItem])
    case taskList([WikiListItem])
    case codeBlock(String)
    case quote([WikiBlock])
    case rule
    case image(url: String?, alt: String)
    case table(WikiTable)
}

struct WikiListItem {
    let blocks: [WikiBlock]
    var isChecked: Bool = false
}

/// A single cell of a wiki table (Tiptap `tableCell`/`tableHeader`, HTML `td`/`th`).
struct WikiTableCell {
    let blocks: [WikiBlock]
    var isHeader: Bool = false
}

/// A wiki table as a row-major grid of cells.
struct WikiTable {
    let rows: [[WikiTableCell]]

    /// Number of columns, based on the widest row.
    var columnCount: Int {
        rows.map { $0.count }.max() ?? 0
    }

    /// Returns the cell at the given row/column, padded with an empty cell if
    /// the row is shorter than `columnCount` (ragged rows).
    func cell(row: Int, column: Int) -> WikiTableCell {
        let cells = rows.indices.contains(row) ? rows[row] : []
        if cells.indices.contains(column) {
            return cells[column]
        }
        return WikiTableCell(blocks: [])
    }
}

/// Converts a wiki page's `Content` into renderable blocks.
enum WikiContent {
    static func blocks(for content: Resources_Common_Content_Content) -> [WikiBlock] {
        switch content.contentType {
        case .tiptapJson:
            guard content.hasTiptapJson else { return [] }
            guard let node = TiptapNode(struct: content.tiptapJson) else { return [] }
            return blocks(from: node)
        case .html:
            if content.hasContent {
                return htmlBlocks(from: content.content)
            }
            if content.hasRawHtml {
                return htmlBlocks(fromRaw: content.rawHtml)
            }
            return []
        default:
            if content.hasContent {
                return htmlBlocks(from: content.content)
            }
            if content.hasRawHtml {
                return htmlBlocks(fromRaw: content.rawHtml)
            }
            return []
        }
    }

    /// Extracts the plain text of a content (used for list snippets/previews,
    /// e.g. the mail inbox). Strips markup, keeps readable whitespace.
    static func plainText(for content: Resources_Common_Content_Content) -> String {
        switch content.contentType {
        case .tiptapJson:
            guard content.hasTiptapJson, let node = TiptapNode(struct: content.tiptapJson) else { return "" }
            return plainText(from: node)
        case .html:
            if content.hasContent {
                return htmlPlainText(from: content.content)
            }
            return content.hasRawHtml ? content.rawHtml : ""
        default:
            if content.hasContent {
                return htmlPlainText(from: content.content)
            }
            return content.hasRawHtml ? content.rawHtml : ""
        }
    }

    // MARK: - Tiptap JSON

    private struct TiptapNode {
        let type: String
        let text: String?
        let attrs: [String: String]
        let marks: [WikiMark]
        let children: [TiptapNode]

        init?(value: Google_Protobuf_Value) {
            guard case .structValue(let structValue)? = value.kind else { return nil }
            self.init(struct: structValue)
        }

        init?(struct structValue: Google_Protobuf_Struct) {
            var type = ""
            var text: String?
            var attrs: [String: String] = [:]
            var marks: [WikiMark] = []
            var children: [TiptapNode] = []
            for (key, fieldValue) in structValue.fields {
                switch key {
                case "type":
                    if case .stringValue(let value)? = fieldValue.kind { type = value }
                case "text":
                    if case .stringValue(let value)? = fieldValue.kind { text = value }
                case "attrs":
                    if case .structValue(let attrsValue)? = fieldValue.kind {
                        for (name, value) in attrsValue.fields {
                            switch value.kind {
                            case .stringValue(let string)?: attrs[name] = string
                            case .numberValue(let number)?: attrs[name] = Self.format(number)
                            case .boolValue(let bool)?: attrs[name] = bool ? "true" : "false"
                            default: break
                            }
                        }
                    }
                case "marks":
                    if case .listValue(let listValue)? = fieldValue.kind {
                        for markValue in listValue.values {
                            guard case .structValue(let markStruct)? = markValue.kind,
                                  case .stringValue(let name)? = markStruct.fields["type"]?.kind,
                                  let mark = WikiMark(name: name, attrs: markStruct.fields) else { continue }
                            marks.append(mark)
                        }
                    }
                case "content":
                    if case .listValue(let listValue)? = fieldValue.kind {
                        children = listValue.values.compactMap { TiptapNode(value: $0) }
                    }
                default:
                    break
                }
            }
            self.type = type
            self.text = text
            self.attrs = attrs
            self.marks = marks
            self.children = children
        }

        private static func format(_ number: Double) -> String {
            number.rounded() == number ? String(Int(number)) : String(number)
        }
    }

    private static func blocks(from node: TiptapNode) -> [WikiBlock] {
        switch node.type {
        case "doc", "root", "container":
            return node.children.flatMap { blocks(from: $0) }
        case "paragraph":
            let inline = inline(from: node.children)
            var blocks: [WikiBlock] = []
            if !inline.isEmpty {
                blocks.append(.paragraph(inline))
            }
            blocks += node.children.compactMap { child in
                guard child.type == "image" else { return nil }
                return WikiBlock.image(url: child.attrs["src"], alt: child.attrs["alt"] ?? "")
            }
            return blocks
        case "heading":
            let level = Int(node.attrs["level"] ?? "") ?? 1
            return [.heading(level: min(max(level, 1), 6), inline(from: node.children))]
        case "bulletList":
            return [.bulletList(listItems(from: node.children))]
        case "orderedList":
            let start = Int(node.attrs["start"] ?? "") ?? 1
            return [.orderedList(start: start, listItems(from: node.children))]
        case "taskList":
            return [.taskList(listItems(from: node.children))]
        case "codeBlock":
            return [.codeBlock(plainText(from: node))]
        case "blockquote":
            return [.quote(node.children.flatMap { blocks(from: $0) })]
        case "horizontalRule":
            return [.rule]
        case "image":
            return [.image(url: node.attrs["src"], alt: node.attrs["alt"] ?? "")]
        case "table":
            return [.table(table(from: node))]
        default:
            let text = plainText(from: node)
            guard !text.isEmpty else { return [] }
            return [.paragraph([.text(text, marks: [])])]
        }
    }

    private static func inline(from nodes: [TiptapNode]) -> [WikiInline] {
        nodes.flatMap { node -> [WikiInline] in
            switch node.type {
            case "text":
                return [.text(node.text ?? "", marks: node.marks)]
            case "hardBreak":
                return [.hardBreak]
            case "checkboxStandalone":
                let checked = node.attrs["checked"] == "true" || node.attrs["data-checked"] == "true"
                return [.checkbox(checked)]
            default:
                return inline(from: node.children)
            }
        }
    }

    private static func listItems(from nodes: [TiptapNode]) -> [WikiListItem] {
        nodes.filter { $0.type == "listItem" || $0.type == "taskItem" }.map { node in
            var item = WikiListItem(blocks: node.children.flatMap { blocks(from: $0) })
            item.isChecked = node.attrs["checked"] == "true"
            return item
        }
    }

    /// Extracts a table grid from a Tiptap `table` node. Rows are `tableRow`
    /// children, cells are `tableHeader`/`tableCell` children.
    private static func table(from node: TiptapNode) -> WikiTable {
        var rows: [[WikiTableCell]] = []
        for rowNode in node.children where rowNode.type == "tableRow" {
            var cells: [WikiTableCell] = []
            for cellNode in rowNode.children {
                guard cellNode.type == "tableHeader" || cellNode.type == "tableCell" else { continue }
                let isHeader = cellNode.type == "tableHeader"
                cells.append(WikiTableCell(
                    blocks: cellNode.children.flatMap { blocks(from: $0) },
                    isHeader: isHeader
                ))
            }
            if !cells.isEmpty {
                rows.append(cells)
            }
        }
        return WikiTable(rows: rows)
    }

    private static func plainText(from node: TiptapNode) -> String {
        var result = node.text ?? ""
        for child in node.children {
            let value = plainText(from: child)
            if !value.isEmpty {
                if !result.isEmpty { result += "\n" }
                result += value
            }
        }
        return result
    }

    // MARK: - Legacy HTML

    private static func htmlBlocks(from rawNode: Resources_Common_Content_RichTextHtmlNode) -> [WikiBlock] {
        // Go's legacy HTML parser sets a parent element's type to .text whenever
        // it contains a text child (e.g. a paragraph becomes type TEXT with a
        // tag + content). Route those container-ish nodes through the tag-driven
        // element path so template content (FromHTML) renders correctly.
        let node: Resources_Common_Content_RichTextHtmlNode
        if rawNode.type == .text, !rawNode.tag.isEmpty, !rawNode.content.isEmpty {
            node = Resources_Common_Content_RichTextHtmlNode.with { $0 = rawNode; $0.type = .element }
        } else {
            node = rawNode
        }

        switch node.type {
        case .doc:
            return node.content.flatMap { htmlBlocks(from: $0) }
        case .element:
            switch node.tag {
            case "p", "div", "span":
                let inline = htmlInline(from: node.content)
                var blocks: [WikiBlock] = []
                if !inline.isEmpty {
                    blocks.append(.paragraph(inline))
                }
                blocks += htmlInlineImages(from: node.content)
                return blocks
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(node.tag.dropFirst()) ?? 1
                return [.heading(level: min(max(level, 1), 6), htmlInline(from: node.content))]
            case "ul":
                if node.attrs["data-type"] == "taskList" {
                    return [.taskList(htmlListItems(from: node.content))]
                }
                return [.bulletList(htmlListItems(from: node.content))]
            case "ol":
                return [.orderedList(start: 1, htmlListItems(from: node.content))]
            case "input":
                // <input type="checkbox"> inside a task item — represented via
                // the enclosing <li> "checked" attribute, so render nothing.
                return []
            case "label":
                return node.content.flatMap { htmlBlocks(from: $0) }
            case "li":
                if node.attrs["data-type"] == "taskItem" {
                    // Task item markup: <li data-type="taskItem" data-checked><label><input/><span>…</span></label></li>
                    return node.content.flatMap { htmlBlocks(from: $0) }
                }
                return node.content.flatMap { htmlBlocks(from: $0) }
            case "blockquote":
                return [.quote(node.content.flatMap { htmlBlocks(from: $0) })]
            case "pre":
                return [.codeBlock(htmlPlainText(from: node))]
            case "hr":
                return [.rule]
            case "img":
                return [.image(url: node.attrs["src"], alt: node.attrs["alt"] ?? "")]
            case "table":
                return [.table(htmlTable(from: node))]
            case "tr", "td", "th":
                return node.content.flatMap { htmlBlocks(from: $0) }
            default:
                return node.content.flatMap { htmlBlocks(from: $0) }
            }
        case .text:
            let text = node.text
            return text.isEmpty ? [] : [.paragraph([.text(text, marks: [])])]
        case .comment, .unspecified, .UNRECOGNIZED:
            return node.content.flatMap { htmlBlocks(from: $0) }
        }
    }

    /// Collects `<img>` elements (at any depth) into image blocks, so images
    /// nested inside paragraphs are not dropped by the inline text parser.
    private static func htmlInlineImages(from nodes: [Resources_Common_Content_RichTextHtmlNode]) -> [WikiBlock] {
        nodes.flatMap { node -> [WikiBlock] in
            if node.type == .element, node.tag == "img" {
                return [.image(url: node.attrs["src"], alt: node.attrs["alt"] ?? "")]
            }
            return htmlInlineImages(from: node.content)
        }
    }

    private static func htmlInline(from nodes: [Resources_Common_Content_RichTextHtmlNode]) -> [WikiInline] {        var result: [WikiInline] = []
        for rawNode in nodes {
            // Same legacy-HTML normalization as htmlBlocks: Go sets an element's
            // type to .text when it has a text child.
            let node: Resources_Common_Content_RichTextHtmlNode
            if rawNode.type == .text, !rawNode.tag.isEmpty, !rawNode.content.isEmpty {
                node = Resources_Common_Content_RichTextHtmlNode.with { $0 = rawNode; $0.type = .element }
            } else {
                node = rawNode
            }

            switch node.type {
            case .text:
                result.append(.text(node.text, marks: []))
            case .element:
                switch node.tag {
                case "br":
                    result.append(.hardBreak)
                case "strong", "b":
                    result += apply([.bold], to: node.content)
                case "em", "i":
                    result += apply([.italic], to: node.content)
                case "u":
                    result += apply([.underline], to: node.content)
                case "s", "strike", "del":
                    result += apply([.strikethrough], to: node.content)
                case "code":
                    result += apply([.code], to: node.content)
                case "a":
                    result += apply([.link(url: node.attrs["href"] ?? "")], to: node.content)
                case "span":
                    // fivenet CheckboxStandalone: <span data-type="checkboxStandalone" data-checked>
                    if node.attrs["data-type"] == "checkboxStandalone" {
                        let dataChecked = node.attrs["data-checked"] ?? ""
                        let checked = node.attrs["checked"] ?? ""
                        let isChecked = dataChecked == "true" || dataChecked == "" || checked == "true" || checked == ""
                        result.append(.checkbox(isChecked))
                    } else {
                        result += htmlInline(from: node.content)
                    }
                default:
                    result += htmlInline(from: node.content)
                }
            case .comment, .unspecified, .UNRECOGNIZED, .doc:
                result += htmlInline(from: node.content)
            }
        }
        return result
    }

    private static func apply(_ marks: [WikiMark], to nodes: [Resources_Common_Content_RichTextHtmlNode]) -> [WikiInline] {
        htmlInline(from: nodes).map { inline in
            switch inline {
            case .text(let string, let existing): return .text(string, marks: existing + marks)
            case .hardBreak: return .hardBreak
            case .checkbox(let checked): return .checkbox(checked)
            }
        }
    }

    private static func htmlListItems(from nodes: [Resources_Common_Content_RichTextHtmlNode]) -> [WikiListItem] {
        nodes.filter { $0.tag == "li" }.map { node in
            var item = WikiListItem(blocks: blocks(fromSubListItem: node))
            // Boolean-Attribute ohne Wert (`<li data-checked>`) liefert Go als
            // leeren String — das zählt wie gesetzt (Web `parseHTML`-Muster).
            let dataChecked = node.attrs["data-checked"] ?? ""
            let checked = node.attrs["checked"] ?? ""
            item.isChecked = dataChecked == "true" || dataChecked == "" ||
                checked == "true" || checked == ""
            return item
        }
    }

    /// Extracts a table grid from an HTML `<table>` node. Rows are `<tr>`
    /// children, cells are `<td>`/`<th>` children.
    private static func htmlTable(from node: Resources_Common_Content_RichTextHtmlNode) -> WikiTable {
        // Go's legacy parser preserves the full HTML tree, so rows can be nested
        // inside `<thead>`/`<tbody>`/`<tfoot>` wrappers (not only direct `<tr>`
        // children). Flatten those wrappers first, then collect the rows.
        func rowNodes(from nodes: [Resources_Common_Content_RichTextHtmlNode]) -> [Resources_Common_Content_RichTextHtmlNode] {
            nodes.flatMap { child -> [Resources_Common_Content_RichTextHtmlNode] in
                guard child.type == .element else { return [] }
                switch child.tag {
                case "thead", "tbody", "tfoot":
                    return rowNodes(from: child.content)
                default:
                    return [child]
                }
            }
        }

        var rows: [[WikiTableCell]] = []
        for rowNode in rowNodes(from: node.content) where rowNode.type == .element && rowNode.tag == "tr" {
            var cells: [WikiTableCell] = []
            for cellNode in rowNode.content where cellNode.type == .element {
                guard cellNode.tag == "td" || cellNode.tag == "th" else { continue }
                let isHeader = cellNode.tag == "th"
                cells.append(WikiTableCell(
                    blocks: cellNode.content.flatMap { htmlBlocks(from: $0) },
                    isHeader: isHeader
                ))
            }
            if !cells.isEmpty {
                rows.append(cells)
            }
        }
        return WikiTable(rows: rows)
    }

    /// Extracts blocks for a single `<li>` of a task list. Task item markup is:
    /// `<li data-checked><label><input type="checkbox"><span>…</span></label>…</li>`.
    private static func blocks(fromSubListItem node: Resources_Common_Content_RichTextHtmlNode) -> [WikiBlock] {
        var result: [WikiBlock] = []
        for child in node.content {
            if child.type == .element, child.tag == "label" {
                result += child.content.flatMap { htmlBlocks(from: $0) }
                continue
            }
            result += htmlBlocks(from: child)
        }
        return result
    }

    private static func htmlPlainText(from node: Resources_Common_Content_RichTextHtmlNode) -> String {
        var result = node.text
        for child in node.content {
            let value = htmlPlainText(from: child)
            if !value.isEmpty {
                if !result.isEmpty { result += "\n" }
                result += value
            }
        }
        return result
    }

    private static func htmlBlocks(fromRaw raw: String) -> [WikiBlock] {
        var html = raw
        html = html.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        html = html.replacingOccurrences(of: "</(p|div|h[1-6]|li|blockquote|pre)>", with: "\n\n", options: .regularExpression)
        html = html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        html = html.replacingOccurrences(of: "&nbsp;", with: " ")
        html = html.replacingOccurrences(of: "&amp;", with: "&")
        html = html.replacingOccurrences(of: "&lt;", with: "<")
        html = html.replacingOccurrences(of: "&gt;", with: ">")
        html = html.replacingOccurrences(of: "&quot;", with: "\"")
        html = html.replacingOccurrences(of: "&#39;", with: "'")
        let paragraphs = html.split(whereSeparator: { $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return paragraphs.map { .paragraph([.text(String($0), marks: [])]) }
    }
}

extension WikiMark {
    fileprivate init?(name: String, attrs: [String: Google_Protobuf_Value]) {
        switch name {
        case "bold": self = .bold
        case "italic": self = .italic
        case "underline": self = .underline
        case "strike": self = .strikethrough
        case "code": self = .code
        case "link":
            var href = ""
            if let value = attrs["href"], case .stringValue(let string)? = value.kind { href = string }
            self = .link(url: href)
        default:
            return nil
        }
    }
}

/// Renders a wiki page's content as SwiftUI views.
struct WikiContentView: View {
    let content: Resources_Common_Content_Content

    @Environment(AppState.self) private var appState

    var body: some View {
        let blocks = WikiContent.blocks(for: content)
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            if blocks.isEmpty {
                Text("Kein Inhalt")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(blocks.indices, id: \.self) { index in
                    WikiBlockView(block: blocks[index], baseURL: appState.client?.baseURL)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct WikiBlockView: View {
    let block: WikiBlock
    let baseURL: URL?

    /// Verfügbare Breite des Content-Bereichs, gegen die Tabellen ihre
    /// Spaltenbreiten verteilen. Wird vom Breiten-Sensor direkt an der Tabelle
    /// gemessen; `0` bedeutet „noch nicht gemessen" → Tabellen fallen auf die
    /// Minimalspaltenbreite zurück (der ScrollView scrollt).
    @State private var tableWidth: CGFloat = 0

    var body: some View {
        switch block {
        case .paragraph(let inline):
            inlineView(inline)
                .font(.body)
                .textSelection(.enabled)
        case .heading(let level, let inline):
            inlineView(inline)
                .font(.system(size: headingSize(for: level), weight: .bold))
                .padding(.top, level <= 2 ? Theme.Spacing.sm : 0)
        case .bulletList(let items):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Text("•")
                        listItemContent(items[index])
                    }
                }
            }
        case .orderedList(let start, let items):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Text("\(start + index).")
                        listItemContent(items[index])
                    }
                }
            }
        case .taskList(let items):
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        checkboxSymbol(isChecked: items[index].isChecked)
                        listItemContent(items[index])
                    }
                }
            }
        case .codeBlock(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(Theme.Spacing.lg)
            }
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        case .quote(let blocks):
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                Rectangle()
                    .fill(.secondary.opacity(0.4))
                    .frame(width: 3)
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    ForEach(blocks.indices, id: \.self) { index in
                        WikiBlockView(block: blocks[index], baseURL: baseURL)
                    }
                }
            }
        case .rule:
            Rectangle()
                .fill(Self.tableSeparator)
                .frame(height: 1.5)
                .padding(.vertical, Theme.Spacing.sm)
        case .table(let table):
            tableContent(table)
        case .image(let url, let alt):
            if let url, let imageURL = Self.resolveImageURL(url, baseURL: baseURL) {
                AuthAsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: Self.imageMaxWidth)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
                    case .failure:
                        Label(alt, systemImage: "photo")
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .center)
            } else {
                Label(alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Maximum inline width for rendered media. Keeps large images from
    /// overflowing the content column (web scales media to ~80% of the editor).
    private static let imageMaxWidth: CGFloat = 320

    @ViewBuilder
    private func checkboxSymbol(isChecked: Bool) -> some View {
        Image(systemName: isChecked ? "checkmark.square.fill" : "square")
            .foregroundStyle(isChecked ? Color.accentColor : Color(.tertiaryLabel))
            .font(.body)
            .padding(.top, 1)
    }

    /// Resolves wiki media `src` values against the configured server base URL,
    /// mirroring the web app's `cleanupImageURL`:
    /// - `/api/filestore/…` and `/images/…` → resolved relative to `baseURL`.
    /// - Absolute `http(s)://` URLs → used as-is.
    /// - Bare relative paths (filestore keys) → prefixed with `/api/filestore/`.
    private static func resolveImageURL(_ string: String, baseURL: URL?) -> URL? {
        if string.hasPrefix("data:image") {
            return nil
        }
        if string.hasPrefix("/api/") || string.hasPrefix("/images/") {
            return URL(string: Self.correctedPath(string), relativeTo: baseURL)?.absoluteURL
        }
        if let url = URL(string: string), url.scheme != nil {
            return url
        }
        guard let baseURL else { return nil }
        let key = string.hasPrefix("/") ? string : "/api/filestore/\(string)"
        return URL(string: Self.correctedPath(key), relativeTo: baseURL)?.absoluteURL
    }

    /// Mirrors the web app's path correction: collapses duplicate slashes that
    /// appear after a served path prefix (e.g. `/api/filestore//key`).
    private static func correctedPath(_ string: String) -> String {
        if string.contains("//") {
            let path = string
            var prefix = ""
            for candidate in ["/api/filestore/", "/api/image_proxy/", "/images/", "/api/"] where path.hasPrefix(candidate) {
                prefix = candidate
                break
            }
            if !prefix.isEmpty {
                let remaining = String(path.dropFirst(prefix.count)).replacingOccurrences(of: "//", with: "/")
                return prefix + remaining
            }
        }
        return string
    }

    @ViewBuilder
    private func listItemContent(_ item: WikiListItem) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(item.blocks.indices, id: \.self) { index in
                WikiBlockView(block: item.blocks[index], baseURL: baseURL)
            }
        }
    }

    /// Eine einzelne sichtbare Tabellen-Zelle: fixe Spaltenbreite, volle
    /// Zeilenhöhe, Zebra-/Header-Hintergrund und rechte Trennlinie. Hintergrund
    /// und Trenner liegen NACH dem `.frame`, damit sie die gesamte Spalte und
    /// Zeilenhöhe abdecken (nicht nur den intrinsischen Textinhalt).
    /// Farbe der inneren Trennlinien (Spalten/Zeilen). Gegenüber `separator`
    /// dezent verstärkt, damit die Linien auch im Hellmodus klar sichtbar sind.
    private static let tableSeparator = Color(.separator).opacity(0.7)

    /// Zebra-Hintergrund für wechselnde Datenzeilen: `secondarySystemFill` ist
    /// ein System-Fill, der im Hell- wie im Dunkelmodus deutlich sichtbar ist.
    private static let tableZebra = Color(.secondarySystemFill)

    @ViewBuilder
    private func tableCell(_ cell: WikiTableCell, rowIndex: Int, width: CGFloat) -> some View {
        let background: Color = cell.isHeader
            ? Theme.Palette.accent.opacity(0.15)
            : (rowIndex.isMultiple(of: 2) ? Color.clear : Self.tableZebra)
        cellContent(cell)
            .frame(width: width, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .background(background)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Self.tableSeparator)
                    .frame(width: 1.5)
            }
    }

    /// Renders a table as a grid with a header row, aligned columns and subtle
    /// cell borders. The available width is measured ONCE by an invisible
    /// sensor wrapped around the table (never on the ScrollView itself); the
    /// column widths are then distributed against it so the table fills the
    /// content column and only scrolls when it truly overflows.
    @ViewBuilder
    private func tableContent(_ table: WikiTable) -> some View {
        let columns = max(table.columnCount, 1)
        let weights = columnWeights(for: table)
        let widths = Self.distributedColumnWidths(weights: weights, available: tableWidth)

        ZStack(alignment: .topLeading) {
            ScrollView(.horizontal, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(table.rows.indices, id: \.self) { rowIndex in
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<columns, id: \.self) { columnIndex in
                                tableCell(
                                    table.cell(row: rowIndex, column: columnIndex),
                                    rowIndex: rowIndex,
                                    width: widths[columnIndex]
                                )
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if rowIndex < table.rows.count - 1 {
                                Rectangle()
                                    .fill(Self.tableSeparator)
                                    .frame(height: 1.5)
                            }
                        }
                    }
                }
                .background(
                    Theme.Palette.surface,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                        .strokeBorder(Color(.separator).opacity(0.8))
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { tableWidth = geo.size.width }
                    .onChange(of: geo.size.width) { _, newWidth in
                        tableWidth = newWidth
                    }
            }
        )
    }

    /// Minimalspaltenbreite. Wird angewendet, wenn die Parent-Breite noch nicht
    /// gemessen wurde oder selbst die Summe aller Minima die verfügbare Breite
    /// übersteigt (dann scrollt der horizontale ScrollView).
    private static let minCellWidth: CGFloat = 96

    /// Pro Spalte ein Inhaltsgewicht (Zeichenzahl der breitesten Zelle). Die
    /// Spaltenbreiten werden proportional zu diesen Gewichten auf die verfügbare
    /// Content-Breite verteilt — die Tabellenbreite selbst kommt IMMER vom
    /// Parent-Container, nie aus dem Tabelleninhalt.
    private func columnWeights(for table: WikiTable) -> [Int] {
        let columns = max(table.columnCount, 1)
        return (0..<columns).map { column in
            var weight = 0
            for rowIndex in table.rows.indices {
                weight = max(weight, Self.textLength(of: table.cell(row: rowIndex, column: column)))
            }
            return max(weight, 1)
        }
    }

    /// Verteilung der Spaltenbreiten auf die verfügbare Content-Breite:
    /// - Keine Breite gemessen (`available <= 0`) → alle Spalten auf
    ///   `minCellWidth`, der ScrollView scrollt, bis die Breite ankommt.
    /// - Passt selbst die Summe der Minima nicht → alle Minima, der ScrollView
    ///   scrollt horizontal (nur bei echter Überbreite).
    /// - Sonst bekommt jede Spalte `minCellWidth` plus den proportional nach
    ///   Inhaltsgewicht verteilten Rest. Die Summe entspricht `available`.
    private static func distributedColumnWidths(weights: [Int], available: CGFloat) -> [CGFloat] {
        let count = weights.count
        guard count > 0 else { return [] }

        guard available > 0 else {
            return Array(repeating: Self.minCellWidth, count: count)
        }

        let minTotal = Self.minCellWidth * CGFloat(count)
        if minTotal >= available {
            return Array(repeating: Self.minCellWidth, count: count)
        }

        let extra = available - minTotal
        var totalWeight: CGFloat = 0
        for column in 0..<count {
            totalWeight += CGFloat(weights[column])
        }

        var result: [CGFloat] = []
        result.reserveCapacity(count)
        for column in 0..<count {
            let width = Self.minCellWidth + extra * (CGFloat(weights[column]) / totalWeight)
            result.append(width)
        }
        return result
    }

    /// Zeichenlänge eines Zelleninhalts (Gewicht für die Spaltenverteilung).
    private static func textLength(of cell: WikiTableCell) -> Int {
        cell.blocks.reduce(0) { $0 + textLength(of: $1) }
    }

    private static func textLength(of block: WikiBlock) -> Int {
        switch block {
        case .paragraph(let inline): return inlineLength(inline)
        case .heading(_, let inline): return inlineLength(inline)
        case .bulletList(let items): return items.reduce(0) { $0 + textLength(of: $1) }
        case .orderedList(_, let items): return items.reduce(0) { $0 + textLength(of: $1) }
        case .taskList(let items): return items.reduce(0) { $0 + textLength(of: $1) }
        case .codeBlock(let code): return code.count
        case .quote(let blocks): return blocks.reduce(0) { $0 + textLength(of: $1) }
        case .rule: return 0
        case .image(_, let alt): return alt.count
        case .table(let table): return table.rows.flatMap { $0 }.reduce(0) { $0 + textLength(of: $1) }
        }
    }

    private static func inlineLength(_ inline: [WikiInline]) -> Int {
        inline.reduce(0) { result, part in
            if case .text(let string, _) = part {
                return result + string.count
            }
            return result + 1
        }
    }

    private static func textLength(of item: WikiListItem) -> Int {
        item.blocks.reduce(0) { $0 + textLength(of: $1) }
    }

    /// Reiner Zelleninhalt ohne Hintergrund/Trennlinien; die Zellen füllen die
    /// Spaltenbreite über `maxHeight: .infinity` aus, damit die Hintergründe
    /// (Header-Tint, Zebra) und Trennlinien die volle Zellenhöhe abdecken.
    @ViewBuilder
    private func cellContent(_ cell: WikiTableCell) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            ForEach(cell.blocks.indices, id: \.self) { index in
                WikiBlockView(block: cell.blocks[index], baseURL: baseURL)
            }
        }
        .font(cell.isHeader ? .body.weight(.semibold) : .body)
        .padding(Theme.Spacing.md)
    }

    /// Rendert Inline-Inhalte. Absätze mit Inline-Checkboxen laufen über
    /// `checkboxFlow` (Icon + Text nebeneinander), reine Text-Absätze über die
    /// performante AttributedString-Variante `inlineText`.
    @ViewBuilder
    private func inlineView(_ inline: [WikiInline]) -> some View {
        if inline.contains(where: { if case .checkbox = $0 { return true } else { return false } }) {
            checkboxFlow(inline)
        } else {
            inlineText(inline)
        }
    }

    /// Absatz-Flow mit Inline-Checkboxen: läuft je Abschnitt in einem HStack,
    /// damit die Checkbox-Symbole direkt im Textfluss stehen.
    private func checkboxFlow(_ inline: [WikiInline]) -> some View {
        var runs: [[WikiInline]] = []
        var current: [WikiInline] = []
        for part in inline {
            if case .checkbox = part {
                if !current.isEmpty { runs.append(current); current = [] }
                runs.append([part])
            } else {
                current.append(part)
            }
        }
        if !current.isEmpty { runs.append(current) }

        return HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            ForEach(runs.indices, id: \.self) { index in
                if case .checkbox(let checked) = runs[index].first {
                    checkboxSymbol(isChecked: checked)
                } else {
                    inlineText(runs[index])
                }
            }
        }
    }

    private func inlineText(_ inline: [WikiInline]) -> Text {
        var text = AttributedString()
        for part in inline {
            switch part {
            case .text(let string, let marks):
                text.append(attributedSegment(string, marks: marks))
            case .hardBreak:
                text.append(AttributedString("\n"))
            case .checkbox:
                // Wird via `checkboxFlow` gerendert; hier nur für Exhaustivität.
                break
            }
        }
        return Text(text)
    }

    private func attributedSegment(_ string: String, marks: [WikiMark]) -> AttributedString {
        var segment = AttributedString(string)
        var font: Font = .system(.body)
        var isLink = false
        var isUnderlined = false
        var isStruckThrough = false
        for mark in marks {
            switch mark {
            case .bold:
                font = font.bold()
            case .italic:
                font = font.italic()
            case .underline:
                isUnderlined = true
            case .strikethrough:
                isStruckThrough = true
            case .code:
                font = .system(.body, design: .monospaced)
            case .link:
                isLink = true
                isUnderlined = true
            }
        }
        segment.font = font
        if isUnderlined {
            segment.underlineStyle = .single
        }
        if isStruckThrough {
            segment.strikethroughStyle = .single
        }
        if isLink {
            segment.foregroundColor = .blue
        }
        return segment
    }

    private func headingSize(for level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 24
        case 3: return 21
        case 4: return 18
        default: return 16
        }
    }
}

/// An image loader that fetches protected media with the current session token,
/// mirroring `AsyncImage`'s phase API. Falls back to `AsyncImage` behavior for
/// public URLs when no auth client is available. Decoded images are cached by
/// URL so repeated loads (e.g. job logos across list rows) hit the memory cache.
struct AuthAsyncImage<Content: View>: View {
    let url: URL
    @ViewBuilder let content: (AsyncImagePhase) -> Content

    @Environment(AppState.self) private var appState
    @State private var phase: AsyncImagePhase = .empty

    var body: some View {
        Group {
            content(phase)
        }
        .task(id: url) {
            if let image = AuthImageCache.image(for: url) {
                phase = .success(Image(uiImage: image))
                return
            }
            phase = .empty
            guard let client = appState.client else {
                await loadPublicImage()
                return
            }
            if let data = await client.authenticatedData(from: url),
               let image = Self.decodeImage(data) {
                AuthImageCache.store(image, for: url)
                phase = .success(Image(uiImage: image))
            } else if url.scheme == "http" || url.scheme == "https" {
                await loadPublicImage()
            } else {
                phase = .failure(Self.loadError())
            }
        }
    }

    /// Decodes image data, falling back to an ImageIO source so WebP (used for
    /// job logos) also loads even though `UIImage(data:)` does not handle it.
    private static func decodeImage(_ data: Data) -> UIImage? {
        if let image = UIImage(data: data) {
            return image
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func loadError() -> NSError {
        NSError(domain: "AuthAsyncImage", code: 1)
    }

    private func loadPublicImage() async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let image = Self.decodeImage(data) else {
                phase = .failure(Self.loadError())
                return
            }
            AuthImageCache.store(image, for: url)
            phase = .success(Image(uiImage: image))
        } catch {
            phase = .failure(error)
        }
    }
}

/// In-memory image cache keyed by URL, shared by every `AuthAsyncImage`
/// instance (job logos, wiki media, profile pictures). Kept non-generic so a
/// static `NSCache` can live here regardless of the image's content closure.
private enum AuthImageCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }
}
