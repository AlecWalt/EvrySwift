# Evry code audit (2026-10-14)

Scope: all 47 Swift files in `Evry/` plus `CalendarTabView.swift` (≈29,000 lines), the asset catalog, bundled fonts and icons, the Xcode project, and the test targets. **Read-only so far — no code has been changed.**

Severity: **H** high, **M** medium, **L** low. Effort: **S** < 1 h, **M** a few hours, **L** a day or more.

---

## 1. Highest-impact improvements

| # | Improvement | Why it matters | Effort |
|---|---|---|---|
| 1 | Stop root and page views re-rendering on every frame or keystroke (ContentView `@Query`s, InboxView reading `drawer.progress` / `pageDrag`, ProfileView `pullDistance`) | The biggest source of jank. Every drag frame, scroll frame or task edit re-evaluates whole screens. | S–M |
| 2 | Debounce the note body save (RTFD encode on every keystroke, and `updateUIView` rebuilding the toolbar every keystroke) | Typing cost grows with note length. This is the remaining notes lag. | M |
| 3 | Push trash, day and folder filters into `@Query` / `#Predicate` and compute derived lists once per body (Inbox, Notes, Profile, Search, Trash, Brain Dump, chat `appData`) | Today most screens load every row and filter it 3–6 times per render. | S each |
| 4 | Cheap `Habit.todayCount` / `isDoneToday` instead of a full `HabitStats` (a year-long day walk) wherever only "done today" is needed, and cache stats per habit | Runs per habit, per render, including at the app root on any change. | S–M |
| 5 | Delete unreachable features: the guided tour, `EventRow`, `LocationPickerSheet`, `AccomplishmentsView` sheet, `InboxDrawerMenu`, the PathView pomodoro widget, unused components and tokens | About 1,100 lines with no behaviour change. | S–M |
| 6 | Put the Profile **Developer** section (trial reset, XP, sample data, saved places) behind `#if DEBUG` | Any user can currently reset the trial; this is also release hygiene. | S |
| 7 | Stop the GPS stream in quick add (`startUpdatingLocation` never stopped; a new manager is allocated each time the view is rebuilt) and unify the 2–3 location helpers | Battery, plus duplicated code. | S |
| 8 | Drop the 7 unused Nunito faces and the two unused bundled app icons (`INCLUDE_ALL_APPICON_ASSETS = YES` with no alternate-icon code) | About 0.9 MB of fonts and about 3 MB of icons out of the bundle; fewer fonts registered at launch. | S |
| 9 | Use one shared palette environment value, one surface (card, field, outline) modifier and one settings-row component | Removes about 34 copies of the palette boilerplate, around 8 near-identical card modifiers, and about 250 lines of settings rows. | M |
| 10 | Split the three 2,000-line files (ProfileView, Components, InboxView) | Maintainability and faster incremental builds. | M |

---

## 2. Findings by category

Within each category, findings are sorted roughly by impact versus effort.

### 2.1 Performance

| Sev | Effort | Location | Finding |
|---|---|---|---|
| H | S | ContentView.swift:37-39 | Three root `@Query`s. `allFolders` and `allNotes` are never read; `allTasks` is used only by the once-a-day recap check. Any task or note change re-renders the whole TabView. Replace with a one-off fetch in `checkDailyRecap`. |
| H | M | InboxView.swift:42, 271-306 | The body reads `drawer.progress`, so the whole Inbox (both pages, both lists, the 731-row date wheel) re-evaluates on every menu-drag frame. That defeats the purpose of `InboxDrawerState`. Move the offset, opacity and overlay into a child view or modifier. |
| H | S | InboxView.swift:29, 105 | `@Query` loads every task including trashed ones, and the computed `tasks` is re-filtered about 8 times per body. Add a `deletedAt == nil` predicate and bind with `let` once. |
| H | S | ProfileView.swift:99, 570-621 | `stats` is a computed property read 5 times per render, each a full `computeStats` including unused streaks. Compute once. |
| H | S | ProfileView.swift:134-145 | `pullDistance` is root `@State` written every overscroll frame, so the whole Profile (stats, `HabitStats`, JSON decode, `UIImage(data:)`) re-renders per frame. Move the pull hint into its own view. |
| H | M | NoteEditorView.swift:49-52 → Note.swift:172, NoteBodyEditor.swift:433 | Every keystroke copies the full attributed string, re-archives it as RTFD and bumps `modifiedAt`, which also invalidates the notes-list `@Query`s behind the sheet. Debounce (about 400 ms) and flush on disappear. |
| M | M | NoteBodyEditor.swift:152-167 | Because the binding is written back per keystroke, `updateUIView` runs per keystroke: it reconfigures colours and insets and replaces `host.rootView`, which rebuilds the formatting bar. Cache the last palette and skip when unchanged. |
| M | M | HabitsView.swift:46; Habit.swift:178-235 | A full `HabitStats` per habit per render, walking each day since creation twice. It re-runs on page changes and animation states. Cache it, or compute streaks only for the focused card. |
| M | S | EvryLevels.swift:238-262; ProfileView.swift:457; EvryChatView.swift:949; EvryActions.swift:252; Habit.swift:252 | A full `HabitStats` just to read `todayDone` / `completedDays`. `DailyGoalXPWatcher` sits at the app root with unfiltered `@Query`s. Add cheap helpers and a predicate. |
| M | S | TaskSheets.swift:53, 1139-1144 | `CurrentLocationProvider` starts GPS updates and never stops; it is re-allocated whenever `AddTaskSheet` is rebuilt. Use a lazy one-shot `requestLocation()` when the location picker opens. |
| M | S | FrequentPlaces.swift:60 | The default argument `= load()` JSON-decodes UserDefaults on every call: every `TaskItem.init` and every title keystroke in quick add and the event editor. Keep an in-memory cache. |
| M | M | InboxView.swift:1206-1229 | `reorderPlan` runs for every row on every drag frame (O(n²) per frame). Compute once per page. |
| M | S | InboxView.swift:844-848, 993-1119 | Each day page filters all tasks, sorts 3 or more times, and `groupedSections` is O(n²) with force unwraps. Use `Dictionary(grouping:)`. |
| M | M | InboxView.swift:60, 141, 422 | `pageDrag` is Inbox root `@State`, so the Schedule/Tasks swipe re-renders everything per frame. Move it into a child that owns the paging. |
| M | S | InboxSchedule.swift:542-552 | One `TimelineView(.periodic 30s)` per card plus the rail, so N+1 timers (task cards ignore `now`). Use one wrapper. |
| M | S | InboxDrawer.swift:176-206 | `TabBarFader` walks every window's view-controller tree on every progress change. Cache a weak tab-bar reference. |
| M | S | InboxDrawer.swift:253-260 | The date wheel builds 731 rows and formats a date per row on every render. Cache the labels. |
| M | S | NotesView.swift:76, 242, 264-353 | Unfiltered `@Query`. `notes`, `filtered`, `pinned` and `dateGroups` are computed 4 or more times per body; search lowercases every note's text per pass. The list is a plain `VStack`, not a `LazyVStack`. |
| M | M | EvryChatView.swift:917-953 | `appData()` fetches all tasks, notes and habits (no predicates) and RTFD-decodes every note before each message, but only 30, 12 and 25 items are used. |
| M | S | EvryChatView.swift:537, 935; EvryActions.swift:243 | `NoteBodyCodec.plainText(note.body)` decodes RTFD to get text that is already stored in `note.plainText`. |
| M | S | BrainDumpSheet.swift:65, 111; EvryChatView.swift:147 | `@State var speech = LiveSpeechInput()` builds an `AVAudioEngine` and `SFSpeechRecognizer` on every parent re-init (State defaults are evaluated each time). Create them lazily. |
| M | S | HabitsView.swift:603-617 | The liquid `TimelineView(.animation)` runs at full refresh rate on every done card, including off-screen neighbours. Cap at 30 fps and pause when the card isn't focused. |
| M | M | MembershipView.swift:122-163, 429-834 | Six `while true` promo loops plus a never-paused `TimelineView(.animation)`. Page TabView keeps neighbours alive, and Reduce Motion is ignored. |
| M | M | CalendarService.swift:124-147; InboxSchedule.swift:483-501 | EventKit is queried on the main thread on every appear, scene activation and each `EKEventStoreChanged`, which arrives in bursts. Debounce and cache by range. |
| H\* | M | CalendarTabView.swift:179, 1263-1280 | `rebuildDotCache` runs a 5-year EventKit query on every tab appear and edit. (\*Only while the hidden Calendar tab is enabled.) |
| M | S | ProfileView.swift:339, 1359, 167-169 | `UIImage(data:)` runs on every render. The full-resolution library photo is decoded before cropping, causing a memory spike; downsample with ImageIO. |
| M | L | Components.swift:1077-1331 | Each row adds its own pan and long-press recognizer to the shared scroll view (2N simultaneous recognizers). A single recognizer with hit-testing would scale better. |
| L | S | ProfileView.swift:2342-2415 | Search `results` is computed 5 times per keystroke. |
| L | S | TaskActions.swift:128-138; ProfileView.swift:2546 | Trash purge and Trash view filter in memory; use a `#Predicate`. |
| L | S | Components.swift:645-651 | The scroll indicator writes `@State` every scroll frame even while hidden. |
| L | S | Note.swift:202-208 | `preview` splits the whole note text into lines on every row render. |
| L | S | Theme.swift:382-398 | 16 font files are registered synchronously at launch; 7 are unused (see §4). |
| L | S | PomodoroModel.swift:236-249 | A 1 s timer allocates a `Task` per tick; use `MainActor.assumeIsolated`. |

### 2.2 Dead code (details and evidence in §4)

| Sev | Effort | Location | Finding |
|---|---|---|---|
| M | M | GuideTourView.swift (271 lines) + ContentView tour code | `TourCoordinator.start()` is never called, so the tour can't run. |
| M | S | AccomplishmentsView.swift:66-277 | `AccomplishmentsView` is only presented by `InboxView.showAccomplishments`, which is never set to true. |
| M | S | InboxDrawer.swift:16-119 | `InboxDrawerMenu` is never constructed; only its `width` constant is used. |
| M | S | TaskSheets.swift:1151-1273 | `LocationPickerSheet` has no references. |
| L | S | EventRow.swift (76 lines) | No references. `CalendarService.importEvent` and `importedEventIDs` exist only for it. |
| L | S | PathView.swift:21-153 | `inFocusMode` is always true, so the pomodoro widget, cover and branches are dead; `PomodoroPhase.statusLabel` with them. |
| L | S | Components.swift | `PaletteReader`, `ProgressArea`, `RoundIconButton`, `PlaceholderTag`; `MultiSelectBar` Move path. |
| L | M | Theme.swift | `AccentColorTheme` (single case); `Appearance.accent` and `Palette.accent` (never read); `successLight`, `dangerLight`, `warningLight`; `evrySkyGlow`; `EvryRadius.band`, `.focus`; `EvrySpace.heading`; `Font.evryDisplay`; `EvryTracking.display`. |
| L | S | Various | Unused members:<ul><li>TaskStats: `todayTotal`, `todayDone`, `total`, `streak`, `longestStreak` and their helpers</li><li>`TaskPriority.chipLabel`</li><li>`TaskGroup.color` and `init(colorHex:)`</li><li>`Folder.color`</li><li>`EvryLevels`: `Progress.toNext`, `CrestTier.next`</li><li>`HabitMedal.gold`, `goldLight`</li><li>`BillingToggleTab.badge`, `BandLayout.navy`</li><li>`AddTaskSheet.defaultDate`</li><li>`EvryAppData.Task.done`, `EvryAppData.Note.modified`</li><li>`EvryPendingDelete.Target.note`</li><li>`ExtractionRing.delay`</li><li>`NoteBodyEditor.placeholder` (never overridden)</li></ul> |
| L | S | InboxView.swift | Seven dead `@State`/`@AppStorage` properties (73-103). Also unused: `emptyMessage` / `emptyMessages`, `onEnterFocusMode` and `onSelectTab` params, `closeMenu(then:)`, `import FoundationModels`, `multiSelectArm`. |
| L | S | ProfileView.swift | Unused `tourCoordinator`, `modelContext` and `context` properties; unused `iconBadge(bg:)` param; an always-true `if`; eleven no-op `#if !os(macOS)` guards. |
| M | M | ProfileView.swift:2012-2017 | Settings with no effect: daily digest, weekly summary, default reminder hour, digest time. Nothing reads these keys. **Product decision: wire them up or remove them.** |
| M | S | SetupFlowView.swift:81 | `user_birthday` is collected (PII) and never read. **Product decision.** |
| L | S | Unused imports | `UserNotifications` (ContentView, TaskActions), `FoundationModels` (InboxView), `UIKit` (NoteEditorView), `SwiftData` (CalendarService, after `importEvent` is removed). |
| L | S | Stale or false comments | <ul><li>TaskParsing.swift:8-9 (claims "note" keyword support)</li><li>InboxView.swift:90, 742, 787</li><li>ContentView.swift:567</li><li>PathView.swift header ("Focus tab")</li><li>NoteEditorView.swift:166 ("Added to Tasks")</li><li>EventRow header</li><li>AddTaskIntent.swift:27</li><li>`AddTaskSheet.defaultDate` doc</li></ul> |
| M | S | EvryChatView.swift:94 | `cycleAllForTesting = true` ships to users, so test greetings ("Aye aye captain o7") appear at any hour. |
| L | S | TaskRowView.swift | One caller always passes `centered: true` and `hideDueDate: true`, never `compact`, so those branches are dead. |
| L | S | Various | Unreachable code:<ul><li>`resolveDateKeyword` regex loop</li><li>`mapItemCoordinate` optional guard</li><li>`CalendarService.ekEvent(withIdentifier:)` fallbacks (always set)</li><li>`next()` cases for `.splash`, `.trial`, `.done`</li><li>a TaskSheets.swift:410 `? 0 : 0` ternary</li></ul> |
| M | M | InboxView.swift:38 + InboxSchedule.swift:37-130 | `inbox_swipe_layout` flag: the old selector layout (about 200 lines) is still switchable from Profile → Layout. **Product decision.** |
| M | M | CalendarTabView.swift (1,342 lines) | The opt-in Calendar tab (default off) is "replaced by Schedule" per comments. It lives outside the synced `Evry/` folder and is added to the project by hand. **Product decision: delete it, or move it into `Evry/`.** |

### 2.3 Duplication

| Sev | Effort | What | Where |
|---|---|---|---|
| M | M | Palette boilerplate (`@Environment` colorScheme + Appearance + `Palette(dark:accent:)`) | About 34 copies across the app |
| M | M | Card / field / outline surface modifiers | `evryCard`, `evryField` (identical output to `evryCard(shadow:false)`), `editCard`, `QuickAddFieldChrome`, Profile `inset`, plus about 19 inline `strokeBorder(palette.hairline)` |
| M | M | Settings rows (same HStack, icon, padding and `evryField` recipe) | About 10 builders in ProfileView, about 250 lines |
| M | M | Tool cover chrome (fill-wipe intro, fade close, first-run explainer) | PomodoroView vs BrainDumpSheet |
| M | S | "Due habits today" rule + `HabitStats.todayDone` | 5 places |
| M | S | Location helpers | `LocationHelper` (SetupFlow), `CurrentLocationProvider` (TaskSheets, twice) |
| M | M | Date parsing | `EvryWhen.parse` / `describe` vs `parseTaskInput` / `resolveDateKeyword` / `formatDueDate`. They behave differently (see bug B1). |
| L | M | MKLocalSearch + distance sort | TaskSheets (×2), FrequentPlaces |
| L | M | `LanguageModelSession` setup | 8 places, each with its own availability check and fallback; none prewarm |
| L | S | "Midnight = no time" check | 6 copies |
| L | S | Editor row, icon and divider builders | EventEditorView vs EditTaskSheet |
| L | S | Five identical `sectionLabel` helpers | ProfileView |
| L | S | Initials and avatar view | ×3 |
| L | S | Photo → crop → save pipeline | ×2 |
| L | S | `usesPrioritiesOften` | EvryChatView vs BrainDumpSheet |
| L | S | Folder creation | NotesView vs NoteEditorView (the latter skips the shade; see bug B9) |
| L | S | `Folder.tint` == `TaskGroup.tint`; `folderInk` repeats `Palette.folderColor` math | Note.swift, Item.swift, NotesView |
| L | S | Burst / pop completion animation | `TaskCheckbox`, `BurstPillButton`, `TrashBurstButton`, PathView, `HabitCheckButton` |
| L | S | Page dots ×3, speech bubbles ×3, rise-in modifiers ×3, H2 title chain ×5 | MembershipView, SetupFlowView |
| L | S | `enclosingScroll` / recognizer scaffolding | `SwipeCatcher` vs `HoldDragCatcher` |
| L | S | Task clone (recurring copy vs duplicate) | TaskActions |
| L | S | `nextWeekdayDate` / `nextWeekday` / `nextWeekend` | TaskActions, TaskParsing |
| L | S | Drag-shadow colour expression | ×4 |
| L | S | "Connect calendar" button | InboxSchedule ×2 |
| L | S | `"pendingSiriTasks"`, `"profile_image_data"`, `tab_*_visible` string keys | Repeated literals across files |

### 2.4 State and data flow

| Sev | Effort | Finding |
|---|---|---|
| M | S | The membership billing toggle is local `@State`. The member page's "billing switch" changes nothing and resets on reopen. |
| L | M | Selection and drag state is prop-drilled through 3 Inbox layers. An `@Observable` in the environment, like `ScheduleDragState`, would remove that. |
| L | S | `RowSwipeZone.middleThirdOnly` is a global static set from view lifecycle. |
| L | S | `app_first_used` has two writers (ProfileView and MembershipAccess). |
| L | S | `xp_awarded_*_<day>` keys grow forever in UserDefaults. |
| L | S | Redundant `await MainActor.run` hops (default MainActor isolation) in several files. |
| L | M | Stored-but-recomputable or duplicated state: `NoteEditorView.bodyText` binding is only read at load; the Profile photo is read in `onAppear` only, so changes made in Settings don't show (see B12). |
| L | S | Unstored, uncancelled `Task`s and `asyncAfter` chains that run after dismissal: SetupFlow place lookups, Brain Dump analyze, `HabitsView.play`, many sequencing delays. |

### 2.5 Backend / persistence usage (SwiftData, EventKit, UserDefaults)

| Sev | Effort | Finding |
|---|---|---|
| H | M | EvryApp.swift:51-66: if the `ModelContainer` fails to open (any migration error), the code **deletes the user's store** and starts fresh (leaving `-wal`/`-shm`). Use a versioned schema and migration plan, and fail loudly or back up first. |
| M | S | Almost every `FetchDescriptor` and `@Query` has no predicate, sort or limit relevant to its use (see §2.1). |
| M | S | `CalendarService.refreshStatus()` is never called, so granting calendar access in Settings or adding calendars isn't picked up until relaunch. |
| L | S | Inconsistent saving: some mutations call `save()`, others rely on autosave. About 40 `try? context.save()` calls swallow errors silently; at least log them in DEBUG. |
| L | S | Large blobs in UserDefaults (profile JPEG, frequent places, AI summaries). This bloats the plist loaded at launch. |
| L | M | Siri-queued tasks are processed only on a scene-phase change, not on cold launch; the queue read and write isn't atomic. |
| L | M | Notifications: no cap for the iOS 64-pending limit; nothing re-syncs when membership or the reminder setting changes. |

### 2.6 Build, bundle and assets

| Sev | Effort | Finding |
|---|---|---|
| M | S | `ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS = YES` with app icon `EvryIcon2`. `Evry.icon` (2.5 MB) and `EvryIcon.icon` (0.7 MB) are bundled, but there is no `setAlternateIconName` anywhere. `AppIcon.appiconset` is empty. |
| M | S | 7 unused Nunito faces (about 135 KB each, about 0.9 MB) are bundled and registered at launch (see §4). |
| L | S | `CalendarTabView.swift` lives outside the synchronized `Evry/` group and is added to the project manually. That is easy to lose and inconsistent. |
| L | S | Xcode warning "Update to recommended settings" (Xcode 27 vs a project last upgraded with 26.6). |
| — | — | No Swift packages or third-party dependencies, so there are no dependency findings. |
| L | S | `README.md`, `beta-test-issues.csv` and `beta-test-report.md` sit at the repo root. They are not bundled; this is repo hygiene only. |

### 2.7 Code quality

| Sev | Effort | Finding |
|---|---|---|
| M | M | Oversized files: ProfileView.swift (2,830 lines, about 17 types), Components.swift (2,220), HabitsView.swift (1,870), InboxView.swift (1,670), SetupFlowView.swift (1,650), MembershipView.swift (1,500), BrainDumpSheet.swift (1,290, one struct with about 25 `@State`). |
| M | M | Very long functions: `InboxView.timelineRow` (about 155 lines), `navGesture` (80), `HabitPage` state machine (8 `@State`, 5 `onChange`). |
| L | S | Magic numbers that must stay in sync by hand: row stride 78 (×3), ring 162/174 vs burst 162/86, `-53`/`64`/`-1200` profile offsets, timings tied to animation lengths. |
| L | S | `static var defaultValue` in PreferenceKeys; these will be errors in Swift 6. |
| L | S | Force unwraps (`t.group!.uid`, `tiers[key]!`); deprecated APIs (`MagnificationGesture`, `.navigationBarLeading`, `openAppWhenRun`, `Task.sleep(nanoseconds:)`). |
| L | S | Internal types that should be `private` (`CardBackground`, `ConfirmPrompt`, `EvryTextFieldStyle`, `NoteFormattingBar`, …). |

### 2.8 Security / reliability (secondary)

| Sev | Effort | Finding |
|---|---|---|
| H | S | The Profile Developer section ships in release: trial reset or expiry, XP, sample events, saved-places dump. |
| H | L | The paywall is a UserDefaults string `membership_plan == "pro"`. Subscribe writes it with no StoreKit purchase. The trial clock (`app_first_used`) resets on reinstall or a plist edit. Already noted as a known mock in project memory; it is pre-release. |
| H | M | The account security UI is mocked: password change, email change, forgot password and 2FA show success without doing anything; "Delete account" only blanks name and email. This is misleading and an App Review risk. |
| M | S | PII in plain UserDefaults: name, email, birthday, home and work addresses with exact coordinates, profile photo. Prefer the Keychain or file-protected storage. |
| H | S | SpeechInput.swift:31-73: if `engine.start()` fails, the tap stays installed, and the next start installs a second tap, which crashes AVAudioEngine. It also mutates observable state off the main thread. |

---

## 3. Bugs found (reported, not fixed)

| # | Sev | Location | Bug |
|---|---|---|---|
| B1 | H | EvryAssistant.swift:62-107 | Distill keeps "tomorrow" in the title and `parseTaskInput` ignores today/tomorrow, so "call mom tomorrow" becomes "Call mom tomorrow" due **today**. This affects Brain Dump and chat Distill. |
| B2 | H | EvryAssistant.swift:352-403 | If the model runs a tool and then fails or returns empty, `fallbackAction` runs as well and creates the task **twice**. |
| B3 | H | AccomplishmentsView.swift:38-48 | Locale-formatted day keys are compared as strings, so pruning can delete today's summary. The same key drives FocusLog and the once-a-day recap guard. |
| B4 | M | ProfileView.swift:291-384 | The name and level title are hard-coded navy, so they are **invisible in dark mode**. |
| B5 | M | ProfileView.swift:1014-1024 | "Clear completed" says "permanently… can't be undone", but tasks only go to Trash. |
| B6 | M | InboxView.swift:650-655 | "Move all to today" drops task times, doesn't reschedule notifications and doesn't save. |
| B7 | M | TaskActions.swift:29-41 | Un-completing a recurring task leaves the spawned next copy, so toggling duplicates it. The copy gets no reminder and loses its location, pin and folder. |
| B8 | M | PomodoroModel.swift:167-228 | Skip counts as a completed session and logs full focus minutes. After backgrounding past a phase end, time is lost and missed phases aren't logged. The final session ends silently. |
| B9 | M | NoteEditorView.swift:177-187 | Folders created from the editor never get a shade. |
| B10 | M | NoteEditorView.swift:102-107 | Clearing an old note's text hard-deletes it on dismiss, bypassing Trash and Undo. |
| B11 | M | FrequentPlaces.swift:226-239 | "No, I don't work there" is read as `.kind("Work")`. |
| B12 | M | ProfileView.swift:157 | A photo changed in Settings doesn't update the Profile tab until it reappears. |
| B13 | M | EvryActions.swift:149-152 | "Remove priority" hits the *delete* branch. |
| B14 | M | EvryActions.swift:340-348 | "In 20min" (no space) is parsed as **20 weeks**. |
| B15 | M | EvryChatView.swift:987-1000 | Chat Distill tasks get no reminder notification. |
| B16 | M | BrainDumpSheet.swift:173/853 | After an error, going back and distilling again still shows the stale error banner. |
| B17 | M | Components.swift:1460 | The quick-add highlighter rewrites text during IME composition, which breaks Japanese, Chinese and Korean input. |
| B18 | M | MembershipView.swift:1045 | Cancel removes access immediately, while the copy promises access "until the end of your billing period". |
| B19 | L | Various | Smaller bugs:<ul><li>snooze doesn't reschedule the notification</li><li>Google Maps detection needs `LSApplicationQueriesSchemes`</li><li>the Apple Maps URL uses `http`</li><li>the date wheel tags only cover ±365 days</li><li>VoiceOver always says "Add task"</li><li>"midnight" rolls to tomorrow</li><li>EditTaskSheet mutates tags and due date just by opening</li><li>rename doesn't update the reminder text</li><li>all-day events moved to a time stay all-day</li><li>`find` matches short titles too loosely</li><li>loose place phrases ("shift", "class", "lift") auto-attach locations</li><li>an empty folder name can be saved</li><li>the habit "all done" celebration fires on delete</li><li>Monday-first locales disagree between views</li><li>Sonar rings never animate</li><li>newline-only input enables Distill and Report</li><li>burst buttons can double-fire</li><li>the cropper offset isn't clamped</li><li>the Siri intent drops tags and priority</li><li>search claims it covers notes but only searches tasks</li></ul> |

---

## 4. Safe-to-delete list

Evidence comes from `rg` over the whole repo, including string literals, `#Preview`s, the `.pbxproj` and asset names. There are no dynamic imports in Swift. String-built names (fonts) are called out explicitly.

| Item | Lines | Confidence | Evidence |
|---|---|---|---|
| `EventRow.swift` | 76 | High | `\bEventRow\b` appears only in its own file. |
| `CalendarService.importEvent`, `importedEventIDs`, `evry_imported_event_ids` key, `import SwiftData` | ~15 | High | The only caller was EventRow; the key string has no other hits. |
| `CalendarEvent.calendarTitle` | 2 | High | Read only by EventRow. |
| `LocationPickerSheet` (+ its `scheduleSearch`) | ~125 | High | No references. |
| `AccomplishmentsView` struct + `InboxView.showAccomplishments` sheet | ~240 | High | The only `AccomplishmentsView(` is in InboxView, gated by a flag never set to true. `AccomplishmentsStore` and `DailyRecapView` stay (they are used). |
| `InboxDrawerMenu` (keep `width` as a constant) | ~104 | High | Never constructed. |
| GuideTourView.swift + ContentView tour overlay and sample-data insert | ~350 | High | `TourCoordinator.start()` has no callers. Keep `cleanupLeftoverTourSampleData` for one release. **Confirm you don't plan to launch the tour.** |
| PathView `inFocusMode` false branch + `PomodoroPhase.statusLabel` | ~60 | High | Both constructors pass `true`. |
| Components: `PaletteReader`, `ProgressArea`, `RoundIconButton`, `PlaceholderTag`, `MultiSelectBar` Move path | ~100 | High | No outside references; one `MultiSelectBar(` call passes `showMove: false`. |
| Theme: `successLight`, `dangerLight`, `warningLight`, `evrySkyGlow`, `EvryRadius.band/.focus`, `EvrySpace.heading`, `Font.evryDisplay`, `EvryTracking.display` | ~15 | High | Zero uses. (These are web-token parity; fine to keep if you prefer.) |
| `AccentColorTheme` cases, helpers, `Appearance.accent`, `Palette.accent` | ~30 (+34 call-site edits) | High | `palette.accent` has zero reads; only `.evry` exists. |
| TaskStats: `todayTotal`, `todayDone`, `total`, `streak`, `longestStreak`, `computeStreak`, `computeLongestStreak`, `completionDays`, `isTodayTask` | ~60 | High | The only consumer (Profile) reads `week`, `month`, `total` and `weekData`. |
| `TaskPriority.chipLabel`, `TaskGroup.color`, `Folder.color`, `Progress.toNext`, `CrestTier.next`, `HabitMedal.gold/goldLight`, `BillingToggleTab.badge`, `BandLayout.navy`, `AddTaskSheet.defaultDate`, `EvryAppData.Task.done`, `EvryAppData.Note.modified`, `ExtractionRing.delay` | ~60 | High | Each has zero readers or is always passed the default. |
| Dead InboxView state and params (§2.2), `emptyMessages` | ~25 | High | Same-name uses belong to `TimelineDayPage`. |
| HabitsView / Habit DEBUG "TEMP" dev tools (`devBackfillCompletedDay`, dev buttons) | ~60 | High | Marked TEMP, DEBUG-only. **Confirm you don't still use them.** |
| Unused imports (listed in §2.2) | ~6 | High | No symbols from those modules are used. |
| Fonts: `Nunito-ExtraLight`, `-ExtraLightItalic`, `-Light`, `-LightItalic`, `-MediumItalic`, `-SemiBoldItalic`, `-BlackItalic` (.ttf) | ~0.9 MB | Medium | No `.light`, `.ultraLight` or `.thin` weights are used anywhere. Italic is only reachable from the notes italic toggle at regular, bold or heavy weight (→ `Italic`, `BoldItalic`, `ExtraBoldItalic`). Names are built dynamically (`"Nunito-\(base)Italic"`), so a fallback to the system font would occur if ever requested. Keep the other 9 faces. |
| `Evry.icon`, `EvryIcon.icon` + set `INCLUDE_ALL_APPICON_ASSETS = NO` | ~3.2 MB | Medium | The app icon is `EvryIcon2`, and there is no alternate-icon API usage. **Confirm these aren't kept as design sources** (they could move outside the target). |
| `AppIcon.appiconset` (empty) | — | High | Contains only `Contents.json`, and the build setting points elsewhere. |
| Items needing a product decision (not "safe"): `CalendarTabView.swift` + `inbox_swipe_layout` selector layout, no-op notification settings, `user_birthday`, `Note.tags` / `sortOrder` / `Folder.colorHex` (schema), `NoteTint.legacy`, `asNunito` migration | ~1,700 | — | Reachable or persisted. Awaiting your call. |

**Estimated removal if everything marked "High" goes:** about 1,450 lines of Swift. The product-decision items would add up to about 1,700 more. Bundle: roughly 4 MB lighter (fonts plus icons).

---

## 5. Refactor plan (small, independently shippable steps)

Each step is one branch commit. Verify every step with a clean build (zero new warnings), the XcodeRefreshCodeIssues check on changed files, and the smoke check listed. **There are no real tests today**: `EvryTests` holds one empty `example()` and the UI tests are templates. There is no linter configured.

| Step | Change | Risk | Verify |
|---|---|---|---|
| 0 | Add minimal Swift Testing tests for the riskiest pure logic: `parseTaskInput` / `EvryWhen.parse` (dates, times, "in 20min"), `PlaceLabels.role` / `statedKind` / `interpretReply`, `FrequentPlaces.match`, `HabitStats` streaks, `TaskActions.toggle` recurrence (in-memory `ModelContainer`), `formatBullets`. These lock in today's behaviour, and the known bugs become `withKnownIssue` tests. | None | Tests pass |
| 1 | Delete high-confidence dead files and types: EventRow, LocationPickerSheet, InboxDrawerMenu, the AccomplishmentsView sheet, the Components and Theme leftovers, unused imports and members | Low | Build; open Inbox, menu wheel, quick add, Profile |
| 2 | Remove the guided tour (after you confirm) | Low | Build; fresh launch and setup flow |
| 3 | `#if DEBUG` around the Profile Developer section and the Habits dev tools; set `cycleAllForTesting = false` | Low | Release build has no dev section; chat greetings respect hours |
| 4 | Root re-render fixes: remove ContentView `@Query`s (fetch on demand), add a predicate to `DailyGoalXPWatcher` | Low | Daily recap still appears; XP still awarded |
| 5 | Inbox: a predicate on `@Query`, `let tasks` once, group by day, page grouping via `Dictionary(grouping:)`, `reorderPlan` once per page, one schedule `TimelineView` | Medium | Inbox paging, reorder, multi-select, folders, schedule rail |
| 6 | Inbox: move `drawer.progress` and `pageDrag` reads into child views; cache the TabBarFader bar and date-wheel labels | Medium | Menu swipe, page swipe, tab-bar fade; check with the Instruments SwiftUI template (before and after body counts) |
| 7 | Profile: compute stats once, isolate the pull hint, cache the decoded photo, downsample picks | Low | Pull-to-search, ring, stats |
| 8 | Habits: `todayCount` / `isDoneToday` helpers, cache `HabitStats`, cap the liquid timeline at 30 fps | Medium | Check-in, streaks, goal reveal, confetti |
| 9 | Notes: debounce body saves (flush on disappear), skip redundant `updateUIView` work, use `note.plainText` instead of decoding, `LazyVStack` and predicate in the list | Medium | Type a long note quickly, then dismiss mid-typing, reopen, and confirm nothing was lost; check formatting toolbar state |
| 10 | Location: one shared one-shot location helper; stop the GPS stream; cache `FrequentPlaces.load()` | Low | Quick-add location search, setup places, auto-location |
| 11 | Chat: predicates and limits in `appData` and the tool fetches; lazy `LiveSpeechInput` | Low | Chat questions and actions, dictation |
| 12 | Bundle: drop 7 font files; drop unused icon sets and set `INCLUDE_ALL_APPICON_ASSETS = NO` (after you confirm) | Low | All text renders (bold, italic, heavy in notes); app icon unchanged; compare `.app` size |
| 13 | Shared palette environment value, replacing about 34 copies (mechanical) | Low–Medium | Light and dark mode on every screen |
| 14 | One `evrySurface` modifier, `SettingsRow`, shared editor rows, `PageDots`, `sectionLabel` | Medium (visual) | Screenshot comparison of Profile, Settings, editors, setup, membership |
| 15 | Consolidate date helpers (`hasTime`, `addDays` usage, `EvryWhen` uses `resolveDateKeyword`) | Medium | Tests from step 0 |
| 16 | Split ProfileView, Components and InboxView into files (no logic changes) | Low | Build only |
| 17 | `static let` PreferenceKeys, deprecated APIs, `private` on file-local types | Low | Build |
| — | **Bugs (§3)**: listed separately. Each fix would be its own commit **after your approval**; none are bundled into the refactor. | — | — |

**Before/after measurement plan:**
- **Code:** `git diff --stat` per step and in total.
- **Bundle:** `.app` size from a Release archive.
- **Rendering:** Instruments SwiftUI "View Body" counts during an Inbox menu drag, a Profile overscroll and 30 s of note typing.
- **Launch:** time-to-first-frame with the App Launch template.

---

## Decisions needed from you before implementation

1. Remove the **guided tour** (unreachable)?
2. Remove the **Calendar tab** (`CalendarTabView.swift`, opt-in, 1.3k lines) and the old **selector inbox layout** (`inbox_swipe_layout`)? Or keep them and move CalendarTabView into `Evry/`?
3. The **no-op notification settings** (digest, weekly summary, default hour): remove them, or keep and wire them up later?
4. **Birthday**: keep collecting it (it is currently unused)?
5. Delete `Evry.icon` and `EvryIcon.icon` from the target, and drop the 7 unused font faces?
6. Developer tools: `#if DEBUG` only (recommended), or keep them in release builds for beta testers?
7. Should any **bugs** in §3 be fixed as part of this work? (Each would be its own commit.)
