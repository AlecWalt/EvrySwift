//
//  EvryApp.swift
//  Evry
//
//  Created by Alec Walter on 7/23/26.
//

import SwiftUI
import SwiftData

@main
struct EvryApp: App {
    @State private var appearance = Appearance()
    @State private var pomodoro = PomodoroModel()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TaskItem.self,
            Project.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // The schema changed out from under an old store (this app
            // replaced the template's Item model) — start fresh rather
            // than crash-loop on a dev-phase store.
            let fresh = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
            do {
                if let url = fresh.url as URL? {
                    try? FileManager.default.removeItem(at: url)
                }
                return try ModelContainer(for: schema, configurations: [fresh])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appearance)
                .environment(pomodoro)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
