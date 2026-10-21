import SwiftUI

struct ContentView: View {
    @State private var limit = 80
    @State private var status = ""
    @State private var lastResult = ""
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prova tecnica: demone di ricarica")
                .font(.headline)

            Stepper("Soglia: \(limit)%", value: $limit, in: 20...100, step: 5)

            HStack {
                Button("Installa demone") { run(.install(limit: limit)) }
                Button("Disinstalla") { run(.uninstall) }
                Button("Aggiorna stato") { refresh() }
            }
            .disabled(isBusy)

            Text(HelperInstaller.isInstalled ? "Demone installato" : "Demone non installato")
                .foregroundStyle(.secondary)

            Text(status)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)

            if !lastResult.isEmpty {
                Text(lastResult)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .onAppear(perform: refresh)
    }

    private func refresh() {
        status = HelperInstaller.status()
    }

    private func run(_ action: HelperInstaller.Action) {
        isBusy = true
        Task {
            // Il dialogo password di osascript blocca il processo chiamante: fuori dal main thread
            let result = await Task.detached { HelperInstaller.perform(action) }.value
            lastResult = result
            isBusy = false
            refresh()
        }
    }
}
