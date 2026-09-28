import SwiftUI

/// What quick add understands. Static help; every entry still opens the editor to confirm before saving.
struct QuickAddGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Type a task with its details in plain words. mise fills in the task and opens the editor so you can check it before saving.")
                }
                Section("Dates & times") {
                    example("call mom tomorrow 6pm")
                    example("dentist next fri 3:30pm")
                    example("report in 3 days")
                    example("movie tonight", "Tonight means 8pm.")
                    example("passport renewal oct 5")
                }
                Section("Repeats") {
                    example("pay rent every 1st 9am")
                    example("standup every weekday 9am")
                    example("gym every monday")
                    example("water plants daily", "Also weekly, biweekly, monthly, yearly.")
                }
                Section("Priority") {
                    example("file taxes !high", "Or !!!")
                    example("book flights !med", "Or !!")
                    example("clean garage !low", "Or !")
                    example("urgent: call the bank", "With Apple Intelligence, words like urgent or important work too.")
                }
                Section("Lists") {
                    example("buy milk #groceries")
                    Text("A typo'd name asks \"Did you mean …?\". A name with no list offers to create it.")
                }
                Section("Voice") {
                    Text("Tap the microphone, say the task, and tap again to finish.")
                    example("buy milk hashtag groceries", "Say \"hashtag\" for #.")
                }
                Section("Siri") {
                    Text("\"Hey Siri, add a task in mise\"")
                }
            }
            .navigationTitle("Quick Add Guide")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func example(_ text: String, _ note: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(text).font(.body.monospaced())
            if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
