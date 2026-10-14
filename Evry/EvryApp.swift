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
    @State private var membershipRouter = MembershipRouter()

    init() {
        // Register the bundled Nunito font files so `.font(.nunito(...))` resolves.
        AppFonts.register()
        // Brand the system tab bar (sky-soft current tab, navy glyphs, Nunito labels).
        EvryTabBarAppearance.apply()
    }

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            TaskItem.self,
            TaskGroup.self,
            Note.self,
            Folder.self,
            Habit.self,
            HabitEntry.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            // The store couldn't be opened (e.g. the schema changed out from
            // under an old store). Start fresh rather than crash-loop — but set
            // the old files aside instead of deleting them, so nothing is lost
            // for good if the failure was something else.
            Self.backUpStore(at: modelConfiguration.url)
            do {
                return try ModelContainer(for: schema, configurations: [modelConfiguration])
            } catch {
                fatalError("Could not create ModelContainer: \(error)")
            }
        }
    }()

    /// Moves the store and its -wal/-shm siblings to "<name>.backup-<time>".
    private static func backUpStore(at url: URL) {
        let fm = FileManager.default
        let stamp = Int(Date().timeIntervalSince1970)
        for suffix in ["", "-wal", "-shm"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fm.fileExists(atPath: file.path) else { continue }
            let backup = URL(fileURLWithPath: file.path + ".backup-\(stamp)")
            if (try? fm.moveItem(at: file, to: backup)) == nil {
                try? fm.removeItem(at: file)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appearance)
                .environment(pomodoro)
                .environment(calendarService)
                .environment(membershipRouter)
                // The one ink colour: navy in light, sky in dark (== palette.primary).
                // Nothing else in the app sets an accent.
                .tint(Color(light: .evryNavy, dark: .evrySky))
                .preferredColorScheme(appearance.preferredColorScheme)
        }
        .modelContainer(sharedModelContainer)
    }
}
