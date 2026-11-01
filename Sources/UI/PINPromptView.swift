import SwiftUI

struct PINPromptView: View {
    @Environment(ConfigStore.self) private var store
    @State private var pin = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    let completion: (Bool) -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text("Parent PIN").font(.title2.bold())
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .focused($focused)
                    .onSubmit(submit)
                if failed {
                    Text("Wrong PIN").foregroundStyle(.red)
                }
                Button("Unlock", action: submit).buttonStyle(.borderedProminent)
            }
            .padding()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { completion(false) }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        if store.verify(pin: pin) {
            completion(true)
        } else {
            failed = true
            pin = ""
        }
    }
}
