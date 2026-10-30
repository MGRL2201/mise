import SwiftUI
import SwiftData

/// Moves a note to a folder (nil = root) from a "Move to…" menu.
private struct MoveMenu: View {
    let note: Note
    @Environment(\.modelContext) private var modelContext
    @Query private var folders: [NoteFolder]

    var body: some View {
        Menu("Move to…", systemImage: "folder") {
            Button("Notes") { move(to: nil) }.disabled(note.folder == nil)
            ForEach(Notes.paths(folders), id: \.folder.id) { folder, path in
                Button(path) { move(to: folder) }.disabled(note.folder === folder)
            }
        }
    }

    private func move(to folder: NoteFolder?) {
        note.folder = folder
        try? modelContext.save()
    }
}

/// One folder level: its subfolders and notes; root (nil) is unfiled notes plus top-level folders (#52).
struct NotesView: View {
    var folder: NoteFolder? = nil
    @Environment(\.theme) private var theme
    @Environment(\.modelContext) private var modelContext
    // ponytail: fetches every folder/note and filters per level; fine for hundreds, predicate on parent if it grows.
    @Query(sort: \NoteFolder.name) private var allFolders: [NoteFolder]
    @Query private var allNotes: [Note]
    @State private var opened: Note?
    @State private var addingFolder = false
    @State private var renaming: NoteFolder?
    @State private var deletingFolder: NoteFolder?
    @State private var deletingNote: Note?
    @State private var name = ""
    @State private var debugOpened = false

    var body: some View {
        let folders = allFolders.filter { $0.parent === folder }
        let notes = Notes.sorted(allNotes.filter { $0.folder === folder })
        Group {
            if folders.isEmpty && notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes", systemImage: "note.text")
                } actions: {
                    Button("New Note", action: newNote)
                }
            } else {
                List {
                    if !folders.isEmpty {
                        Section("Folders") { ForEach(folders, content: folderRow) }
                            .listRowBackground(Color(theme.surface))
                    }
                    if !notes.isEmpty {
                        Section("Notes") { ForEach(notes, content: noteRow) }
                            .listRowBackground(Color(theme.surface))
                    }
                }
            }
        }
        .navigationTitle(folder?.name ?? "Notes")
        .themedBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Folder", systemImage: "folder.badge.plus") { name = ""; addingFolder = true }
                Button("New Note", systemImage: "square.and.pencil", action: newNote)
            }
        }
        .navigationDestination(item: $opened) { NoteDetailView(note: $0) }
        #if DEBUG
        .onAppear {
            // Screenshot hook: `-miseNote "Shopping list"` opens that root note, once per launch.
            if folder == nil && !debugOpened, let title = UserDefaults.standard.string(forKey: "miseNote") {
                debugOpened = true
                opened = allNotes.first { $0.title == title }
            }
        }
        #endif
        .alert("New Folder", isPresented: $addingFolder) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") { addFolder() }
        }
        .alert("Rename Folder", isPresented: Binding { renaming != nil } set: { if !$0 { renaming = nil } }, presenting: renaming) { target in
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { target.name = trimmed; try? modelContext.save() }
            }
        }
        .confirmationDialog("Delete Folder?", isPresented: Binding { deletingFolder != nil } set: { if !$0 { deletingFolder = nil } },
                            presenting: deletingFolder) { target in
            Button("Delete \(target.name)", role: .destructive) { try? Notes.delete(target, context: modelContext) }
        } message: { _ in
            Text("Its notes and subfolders move to \(folder?.name ?? "Notes").")
        }
        .confirmationDialog("Delete Note?", isPresented: Binding { deletingNote != nil } set: { if !$0 { deletingNote = nil } },
                            presenting: deletingNote) { target in
            Button("Delete \(target.title)", role: .destructive) {
                modelContext.delete(target)
                try? modelContext.save()
            }
        }
    }

    private func folderRow(_ child: NoteFolder) -> some View {
        NavigationLink {
            NotesView(folder: child)
        } label: {
            LabeledContent {
                Text("\(child.notes?.count ?? 0)")
            } label: {
                Label(child.name, systemImage: "folder")
            }
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = child }
            Button("Rename", systemImage: "pencil") { name = child.name; renaming = child }
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { name = child.name; renaming = child }
            Button("Delete", systemImage: "trash", role: .destructive) { deletingFolder = child }
        }
    }

    private func noteRow(_ note: Note) -> some View {
        NavigationLink {
            NoteDetailView(note: note)
        } label: {
            HStack {
                if note.pinned { Image(systemName: "pin.fill").foregroundStyle(.orange).accessibilityLabel("Pinned") }
                Text(note.title).lineLimit(1)
                Spacer()
                Text(note.modified, format: .dateTime.day().month()).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .swipeActions(edge: .leading) {
            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { togglePin(note) }
                .tint(.orange)
        }
        .swipeActions(edge: .trailing) {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingNote = note }
        }
        .contextMenu {
            Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { togglePin(note) }
            MoveMenu(note: note)
            Button("Delete", systemImage: "trash", role: .destructive) { deletingNote = note }
        }
    }

    private func togglePin(_ note: Note) {
        note.pinned.toggle()
        try? modelContext.save()
    }

    private func newNote() {
        let note = Note()
        modelContext.insert(note)
        note.folder = folder
        opened = note
    }

    private func addFolder() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let new = NoteFolder(name: trimmed)
        modelContext.insert(new)
        new.parent = folder
        try? modelContext.save()
    }
}

/// Rich note editor (formatting toolbar, Markdown shortcuts) with a raw Markdown toggle, pin, move and shared tags (#52, #54).
struct NoteDetailView: View {
    @Bindable var note: Note
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTag = ""
    @State private var attributed: AttributedString
    @State private var selection = AttributedTextSelection()
    @State private var baseline: String
    @State private var parsed: AttributedString  // last programmatic load
    @State private var raw = false
    @FocusState private var focused: Bool

    init(note: Note) {
        _note = Bindable(note)
        let text = NoteMarkdown.attributed(note.body)
        _attributed = State(initialValue: text)
        _parsed = State(initialValue: text)
        _baseline = State(initialValue: NoteMarkdown.markdown(text))
    }

    var body: some View {
        let tags = (note.tags ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(tags) { tag in
                        HStack(spacing: 4) {
                            Text(tag.name)
                            Button("Remove Tag \(tag.name)", systemImage: "xmark") { note.tags?.removeAll { $0 === tag } }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.quaternary, in: Capsule())
                    }
                    TextField("Add Tag", text: $newTag)
                        .frame(minWidth: 80)
                        .onSubmit { addTag(newTag); newTag = "" }
                    let available = allTags.filter { tag in !tags.contains { $0 === tag } }
                    if !available.isEmpty {
                        Menu("Existing Tags") {
                            ForEach(available) { tag in Button(tag.name) { addTag(tag.name) } }
                        }
                        .fixedSize()
                    }
                }
                .padding(.horizontal)
            }
            Group {
                if raw {
                    TextEditor(text: Binding { note.body } set: { new in
                        guard new != note.body else { return }
                        note.body = new
                        note.modified = .now
                    })
                    .font(.body.monospaced())
                } else {
                    TextEditor(text: $attributed, selection: $selection)
                }
            }
            .writingToolsBehavior(.complete)
            .focused($focused)
            .padding(.horizontal)
        }
        .navigationTitle(note.title)
        .themedBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(raw ? "Show Formatted" : "Show Markdown", systemImage: raw ? "textformat" : "chevron.left.forwardslash.chevron.right") {
                    if raw { load() }
                    raw.toggle()
                }
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { note.pinned.toggle() }
                MoveMenu(note: note)
            }
            if !raw {
                #if os(iOS)
                // Nine buttons overflow the iPhone width; scroll them in one keyboard item.
                ToolbarItem(placement: .keyboard) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 20) { formatButtons }.labelStyle(.iconOnly)
                    }
                }
                #else
                ToolbarItemGroup(placement: .automatic) { formatButtons }
                #endif
            }
        }
        // ponytail: full serialize per keystroke; debounce if long notes lag.
        .onChange(of: attributed) { old, new in
            if new != parsed {  // skip programmatic loads so escaped literals like "\- x" don't become bullets
                NoteEditing.continueList(old: old, text: &attributed, selection: &selection)
                NoteEditing.applyShortcuts(old: old, text: &attributed, selection: &selection)
            }
            NoteEditing.commit(attributed, to: note, baseline: &baseline)
        }
        .onDisappear { try? modelContext.save() }
        #if DEBUG
        .task { await debugScript() }
        #endif
    }

    // ponytail: no ⌘B/⌘I shortcuts; checkboxes toggle from the toolbar on the cursor line only (TextEditor has no per-character tap target).
    @ViewBuilder private var formatButtons: some View {
        Button("Bold", systemImage: "bold") { NoteEditing.toggle(.stronglyEmphasized, in: &attributed, selection: &selection) }
        Button("Italic", systemImage: "italic") { NoteEditing.toggle(.emphasized, in: &attributed, selection: &selection) }
        Button("Strikethrough", systemImage: "strikethrough") { NoteEditing.toggle(.strikethrough, in: &attributed, selection: &selection) }
        Button("Code", systemImage: "chevron.left.forwardslash.chevron.right") { NoteEditing.toggle(.code, in: &attributed, selection: &selection) }
        Menu("Heading", systemImage: "textformat.size") {
            ForEach(1...3, id: \.self) { level in
                Button("Heading \(level)") { NoteEditing.toggleHeading(level, in: &attributed, selection: &selection) }
            }
        }
        Button("Bullet", systemImage: "list.bullet") { NoteEditing.toggleBullet(in: &attributed, selection: &selection) }
        Button("Numbered", systemImage: "list.number") { NoteEditing.toggleNumbered(in: &attributed, selection: &selection) }
        Button("Checkbox", systemImage: "checklist") { NoteEditing.toggleCheckbox(in: &attributed, selection: &selection) }
        Button("Quote", systemImage: "text.quote") { NoteEditing.toggleQuote(in: &attributed, selection: &selection) }
    }

    /// Reparses the body after raw editing; the onChange skips shortcuts and commits nothing for it.
    private func load() {
        let text = NoteMarkdown.attributed(note.body)
        parsed = text
        attributed = text
        selection = AttributedTextSelection()
        baseline = NoteMarkdown.markdown(text)
    }

    private func addTag(_ name: String) {
        guard let tag = try? Tag.named(name, in: modelContext), !(note.tags ?? []).contains(where: { $0 === tag }) else { return }
        note.tags = (note.tags ?? []) + [tag]
    }

    #if DEBUG
    /// Screenshot hook: `-miseNoteScript YES` types and formats sample text through the editor's own paths; `-miseNoteRaw YES` then shows the Markdown.
    private func debugScript() async {
        guard UserDefaults.standard.bool(forKey: "miseNoteScript") else { return }
        try? await Task.sleep(for: .milliseconds(500))
        focused = true
        selection = AttributedTextSelection(insertionPoint: attributed.endIndex)
        // Extra Returns end the seeded checklist and the quote, which Return otherwise continues.
        for ch in "\n\n## Typed heading\nbody text\n- one\ntwo\n\n1. first\nsecond\n\n> quoted\n\n```\nlet x = 1\n```\nafter" {
            attributed.replaceSelection(&selection, withCharacters: String(ch))
            try? await Task.sleep(for: .milliseconds(100))  // 30 ms coalesced keystrokes into one onChange
        }
        let marks: [(String, InlinePresentationIntent)] = [("body", .stronglyEmphasized), ("text", .emphasized), ("two", .strikethrough)]
        for (word, intent) in marks {
            guard let r = attributed.range(of: word) else { continue }
            selection = AttributedTextSelection(range: r)
            NoteEditing.toggle(intent, in: &attributed, selection: &selection)
        }
        if let r = attributed.range(of: "Milk") {
            selection = AttributedTextSelection(insertionPoint: r.lowerBound)
            NoteEditing.toggleCheckbox(in: &attributed, selection: &selection)
        }
        selection = AttributedTextSelection(insertionPoint: attributed.endIndex)
        raw = UserDefaults.standard.bool(forKey: "miseNoteRaw")
    }
    #endif
}
