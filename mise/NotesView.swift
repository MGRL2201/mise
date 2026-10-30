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

    var body: some View {
        let folders = allFolders.filter { $0.parent === folder }
        let notes = Notes.sorted(allNotes.filter { $0.folder === folder })
        // ZStack, not Group: Group pushes .onAppear onto each branch, so the empty-to-List flip would sweep a new note.
        ZStack {
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
        .onAppear {
            // Sweep blank notes here, not in NoteDetailView.onDisappear, which also fires on a tab switch.
            for note in allNotes where note.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { modelContext.delete(note) }
            try? modelContext.save()
        }
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

/// Plain Markdown text editor with pin, move and shared tags; #54 replaces the editor (#52).
struct NoteDetailView: View {
    @Bindable var note: Note
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Tag.name) private var allTags: [Tag]
    @State private var newTag = ""

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
            TextEditor(text: $note.body)
                .padding(.horizontal)
        }
        .navigationTitle(note.title)
        .themedBackground()
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button(note.pinned ? "Unpin" : "Pin", systemImage: note.pinned ? "pin.slash" : "pin") { note.pinned.toggle() }
                MoveMenu(note: note)
            }
        }
        .onChange(of: note.body) { note.modified = .now }
        .onDisappear { try? modelContext.save() }
    }

    private func addTag(_ name: String) {
        guard let tag = try? Tag.named(name, in: modelContext), !(note.tags ?? []).contains(where: { $0 === tag }) else { return }
        note.tags = (note.tags ?? []) + [tag]
    }
}
