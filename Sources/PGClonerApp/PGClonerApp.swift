import Logging
import Sparkle
import SwiftUI

@main
struct PGClonerApp: App {
    #if PGCLONER_OBSERVATION_MACRO
    @State private var model: AppModel
    #else
    @StateObject private var model: AppModel
    #endif
    private let updaterController: SPUStandardUpdaterController

    init() {
        LoggingSystem.bootstrap { PGClonerOSLogHandler(label: $0) }
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        let model = AppModel()
        #if PGCLONER_OBSERVATION_MACRO
        _model = State(initialValue: model)
        #else
        _model = StateObject(wrappedValue: model)
        #endif
    }

    var body: some Scene {
        WindowGroup("PG Cloner") {
            MainView(model: model)
                .frame(minWidth: 1_100, minHeight: 720)
                .task {
                    await model.bootstrap()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
            CommandGroup(after: .appSettings) {
                Button("Reset Session") {
                    model.resetSession()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 820, height: 590)
        }
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}

@MainActor
private final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}
