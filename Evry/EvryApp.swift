//
//  EvryApp.swift
//  Evry
//
//  Created by Alec Walter on 7/23/26.
//

import SwiftUI
import SwiftData
import UserNotifications

// Allows notification banners to appear even while the app is in the foreground.
class EvryAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

@main
struct EvryApp: App {
    @UIApplicationDelegateAdaptor(EvryAppDelegate.self) private var appDelegate
    @State private var appearance = Appearance()
    @State private var pomodoro = PomodoroModel()
    @State private var calendarService = CalendarService()
    @State private var tourCoordinator = TourCoordinator()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TaskItem.self,
            Note.self,
            Folder.self,
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
                .environment(calendarService)
                .environment(tourCoordinator)
                .preferredColorScheme(appearance.preferredColorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
