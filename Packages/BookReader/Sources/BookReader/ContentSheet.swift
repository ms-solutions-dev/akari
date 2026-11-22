import DesignSystem
import SwiftUI

/// Table of contents and search in one sheet: the chapters with page number, the
/// current one marked; a search word at the top swaps the list for the hits with
/// context.
struct ContentSheet: View {

    let controller: BookController
    let search: Bool
    /// Preset search word - "All places" in the term sheet, "Search in book" in the selection menu.
    var preset: String? = nil
    /// Spoiler protection for "All places": only hits up to this fraction of the book.
    var untilFraction: Double? = nil

    @State private var searchText = ""
    @State private var hit: [BookController.Hit] = []
    @State private var sought = false
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if !searchText.isEmpty {
                    hitList
                } else {
                    contentList
                }
            }
            .paper()
            .navigationTitle(Text(app: search ? "book.search" : "book.content"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $searchText,
                placement: .navigationBarDrawer(displayMode: search ? .always : .automatic),
                prompt: Text(app: "book.search")
            )
            .onSubmit(of: .search) { Task { await searchNow() } }
            .task {
                guard let preset, searchText.isEmpty else { return }
                searchText = preset
                await searchNow()
            }
            .onChange(of: searchText) { _, new in
                if new.isEmpty {
                    hit = []
                    sought = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Text(app: "action.done")
                    }
                }
            }
        }
    }

    private var contentList: some View {
        ScrollViewReader { reader in
            List(controller.content) { entry in
                let current = entry.id == controller.currentEntry?.id
                Button {
                    controller.jump(to: entry)
                    dismiss()
                } label: {
                    HStack {
                        Text(verbatim: entry.name)
                            .font(current ? .body.weight(.semibold) : .body)
                            .lineLimit(2)
                        Spacer()
                        if let page = controller.page(from: entry) {
                            Text(verbatim: String(page))
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.leading, CGFloat(entry.depth) * 16)
                    .frame(minHeight: TapTarget.atLeast)
                }
                .foregroundStyle(current ? Color.accentColor : Color.primary)
                .id(entry.id)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
            .listStyle(.plain)
            .onAppear {
                if let current = controller.currentEntry { reader.scrollTo(current.id, anchor: .center) }
            }
        }
    }

    @ViewBuilder
    private var hitList: some View {
        if running {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if sought, hit.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            List {
                if sought {
                    Text(verbatim: Wording.phrase("book.hits", hit.count))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowSeparator(.hidden)
                }
                ForEach(hit) { t in
                    Button {
                        controller.show(t)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(t.before)\(Text(verbatim: t.text).bold())\(t.after)")
                                .font(.subheadline)
                                .lineLimit(3)
                            if let chapter = t.chapter {
                                Text(verbatim: chapter)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .foregroundStyle(.primary)
                }
            }
            .listStyle(.plain)
        }
    }

    private func searchNow() async {
        running = true
        let all = await controller.search(searchText)
        hit =
            untilFraction.map { until in all.filter { ($0.locator.locations.totalProgression ?? 0) <= until }
            }
            ?? all
        sought = true
        running = false
    }
}

/// A footnote as a sheet over the text, not as a jump - Readium
/// passes its content as HTML; only the words are shown here.
struct FootnoteSheet: View {

    let html: String
    let theme: ReadingStyle.ReadingTheme

    var body: some View {
        ScrollView {
            Text(verbatim: FootnoteSheet.words(html))
                .font(.body)
                .foregroundStyle(theme.inkColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
        }
        .background(theme.paperColor)
        .presentationBackground(theme.paperColor)
    }

    /// Markup removed, entities resolved, whitespace collapsed.
    static func words(_ html: String) -> String {
        var text = html.replacingOccurrences(
            of: "</p>|</div>|</li>|</h[1-6]>", with: "\n\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        for (entity, character) in [
            ("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
            ("&#8217;", "’"), ("&#8220;", "“"), ("&#8221;", "”"),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\n\\s*\\n+", with: "\n\n", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
