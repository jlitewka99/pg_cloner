import Logging
import SwiftUI

@main
struct PGClonerApp: App {
    #if PGCLONER_OBSERVATION_MACRO
    @State private var model: AppModel
    #else
    @StateObject private var model: AppModel
    #endif

    init() {
        LoggingSystem.bootstrap { PGClonerOSLogHandler(label: $0) }
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
