# The Core

A compact, structured profile of how someone uses Evry, built up from app usage so on-device features can fit the app to them. The Core keeps **summaries, not logs**: events feed it, but only the distilled result is stored. It never sends anything off the device.

Code: `Evry/Core/`

| File | What it holds |
| --- | --- |
| `CoreModel.swift` | Data model, events, `CoreConfig`, `CoreProgress` |
| `CoreLearner.swift` | Update rules: decay, confidence, rhythms, task stats, habits, place clustering, pruning, progress |
| `CoreFacts.swift` | `NoteFactExtracting` + rule and on-device-model extractors, fact merging |
| `CoreContext.swift` | `getContext(purpose)` slicing |
| `CoreReadout.swift` | `getView()`: the profile in readable sections |
| `EvryCore.swift` | Engine and public API, storage, schema migration, location sampling |
| `CoreHooks.swift` | Bridges from `TaskItem` / `Habit` / `Note` to Core events; task-type classifier |
| `CoreView.swift` | The crystal visualizer, the progress card, and the Core sheet |

## Public API (`EvryCore.shared`, main actor)

| Call | Does |
| --- | --- |
| `record(_ event: CoreEvent, at:)` | Folds one event in. Cheap and synchronous. Never throws. |
| `getContext(_ purpose: CorePurpose) -> CoreContextSlice` | A minimal slice for a model call |
| `getView() -> CoreReadout` | Readable sections for the UI |
| `updateDeclared { $0.… }` | Edits the person's own preferences |
| `deleteEntry(_ ref: CoreEntryRef)` | Forgets one entry (place, fact, habit, task type, rhythms, goal…) |
| `reset()` | Forgets everything, including consent, and erases the file |
| `renamePlace`, `setPlaceCategory`, `confirmFact` | Corrections from the Core sheet |
| `setLocationConsent(_:deleteData:)`, `setNoteConsent(_:deleteData:)` | Layer 2 switches |
| `progress` | How close the Core is to its desired size |

## Data model

`CoreProfile` follows the spec's shape. These are the deliberate differences:

- **`meta`**: `userId` is a random on-device UUID with no link to any account. `schemaVersion`, `createdAt`/`updatedAt`, `consent { location, noteExtraction }` (both off by default), and `lastHabitSweep`.
- **`declared`**: `quietHours` ("HH:mm" pairs, may wrap midnight), `goals`, `suppressed`, `nudgeLevel`, `placeLabels`, plus `placeCategories` (user category overrides).
- **`places`**: `CorePlace` has the label and `labelSource`, a coarse `center`, `radiusM`, `category`, `visits`, `lastVisit`, `typicalWindows` (derived from sparse `visitBins`), `linkedTaskTypes` (decay-weighted), and `confidence`.
- **`placeCandidates`**: clusters below the visit threshold. They are learning state only: never shown as places and never put in a slice.
- **`rhythms`**: decay-weighted 24-hour and 7-day histograms for all activity, planning and completion. `activeHours`/`activeDays`/`planningHours`/`completionHours` are their normalized views (busiest bucket = 1). `weeklyShape` is derived ("Sunday planner", "front-loaded", "back-loaded", "weekend-heavy", "steady").
- **`habits`**: `CoreHabit` has the spec's fields. `usualTime` comes from a circular mean of check-in times, so 23:00 and 01:00 average to midnight. `usualPlaceId` needs ≥ 60% of attributed check-ins at one place. `slipPattern` compares the miss rate on weekends with weekdays, or finds a single bad weekday.
- **`taskStats`**: decay-weighted counters per task *type* (`created`, `completed`, `pushed`, `snoozed`, `abandoned`, `completeHours`). `taskBehavior` (the spec's `TaskBehavior`) is derived from them. Task titles are never stored. A rule classifier (`CoreTaskTypes`) sorts tasks into health, fitness, errand, chores, work, admin, social, study, creative or other, and a tag that names a type wins.
- **`facts`**: `CoreFact` stores the kind, a summary of at most 6 words, `sourceNoteId`, `firstSeen`/`lastSeen`, `confidence` (current), `evidence` (as of `lastSeen`) and `userConfirmed`.
- **`feedback`**: lifetime nudge counts, decay-weighted counts per nudge type (`acceptRateByNudgeType` is derived), and `mascotEngagement` (0…1).

## Layers

- **Layer 1** (always on): tasks, habits and rhythms. These work fully without any permission.
- **Layer 2** (consent-gated): places and note facts. When a switch is off, those modules do nothing: no location fix is requested, note text isn't even assembled, and their sections stay empty. Turning a switch off stops collection immediately, and the UI offers to delete what that module produced.

## Update rules

All tunables live in `CoreConfig`.

- **Decay**: every counter is multiplied by `0.5^(elapsed / halfLife)` before it's updated, so recent behaviour counts more. Half-lives:
  - rhythms: 30 days
  - tasks: 30 days
  - habits: 21 days
  - places: 45 days
  - facts: 90 days
- **Confidence** is evidence × recency × consistency:
  - evidence `1 − e^(−n/k)` saturates with more observations
  - recency is the decay factor since the entry was last seen
  - consistency is used for habits (how tightly check-in times cluster); scattered times count as contradictions and lower it

  Confidences are recomputed from stored evidence on every pass, never compounded, so `maintain()` is idempotent.
- **Avoidance**: only a move to a *later day* counts as a push. Dropping a task into a time slot today is planning. A type is "avoided" once it has ≥ 3 pushes or snoozes on ≥ 50% of its tasks.
- **Places**:
  - Samples are rounded to 3 decimals (~100 m) *before* anything else happens.
  - A sample joins the nearest known place or candidate within 150 m.
  - Samples at the same spot within 60 minutes count as one visit.
  - A candidate becomes a Place at **3 visits** (`placeMinVisits`).
  - Only three moments trigger a sample: task completion (links the task type), app open, and a task whose location matches a saved setup place (links the type only, not a visit).
  - A fix the system already has from the last 5 minutes is reused. There is never continuous tracking and no trail is kept.
- **Category guess**: nights → home, weekday 9–5 → work, mostly fitness tasks → gym, mostly errands → store. A guess is made only when one pattern holds ≥ 60% of the evidence *and* the place's confidence is ≥ 0.7, which in practice means about 5 visits.
- **Declared beats inferred**: `declared.placeLabels` and `declared.placeCategories` always win, and inference never writes to `declared`. Places the person named are never pruned. Confirmed facts never decay.
- **Facts**:
  - Seeing a fact again (in another note, or a later day) raises its evidence by 30% of the remaining gap.
  - If a note is re-saved without a fact it used to support, that fact's evidence halves.
  - Deleting a note drops its unconfirmed facts.
- **Prune**:
  - inferred places, unconfirmed facts and habit patterns below `pruneThreshold` (0.15)
  - candidates not seen for 90 days
  - task types with almost no weight left
  - `maintain()` runs on every app open
- **Habit misses**: on app open, `CoreHooks.sweepHabits` records a miss for each scheduled, unmet day since the last sweep (at most a week back). It also refreshes streaks and drops profiles for deleted or built habits.

## Where it shows

- **Profile page: the crystal.**
  - The Core sits *behind* the profile photo on a two-seat carousel (`ProfileCarousel` in `ProfileView.swift`). Swiping either way spins the photo and the Core round so they trade places.
  - The swipe is read from a transparent horizontal paging `ScrollView` nested in the page's vertical scroll, so vertical drags that start on the photo still scroll the page. Don't replace it with a `DragGesture`, because that swallowed vertical scrolls.
  - `CoreCrystal` is 12 facets: an empty outline at 0%, one more facet per twelfth of progress (from the base up), complete at 100%. It sits in the same medallion as the photo, with a circular progress ring and a "Core · N%" pill.
  - The carousel peeks once on first visit so the Core gets noticed.
- **Settings → Developer → Your Core**: the progress card and the full Core sheet (consent, preferences, every entry, reset).

## Desired size

Each module fills toward a target. The overall score is the weighted average over **active** modules only, so turning a switch off (or having no habits) never blocks reaching 100%.

| Module | Target | Weight | Active when |
| --- | --- | --- | --- |
| Tasks | 120 task events | 0.30 | always |
| Rhythms | 21 active days | 0.25 | always |
| Habits | 42 check-ins / misses | 0.20 | a habit exists |
| Places | 3 places | 0.15 | location consent |
| Notes | 5 facts | 0.10 | note consent |

Progress uses lifetime counters, so the bar never slides back while the person is just away for a while. The profile's *contents* still fade.

## Calling `getContext` from an AI feature

**In use:** Evry's chat (`EvryConversation.modelReply` in `EvryAssistant.swift`) adds `getContext(.general).json` to its prompt once the Core has learned anything (`conf > 0`). The instructions tell the model to use it quietly and never mention it.

```swift
let slice = EvryCore.shared.getContext(.taskPlanning)
let prompt = """
    About this person (use it to adapt, never mention it): \(slice.json)
    …
    """
```

Purposes and what they include:

| Purpose | Contents |
| --- | --- |
| `.reminders` | quiet hours, nudge level, peak hours/days, usual finishing hours, week shape, avoided types |
| `.locationSuggestions` | places: label, category, windows ("Mon 9-17"), linked task types. **No coordinates** |
| `.habitCoaching` | habit profiles (title, cadence, streaks, 30-day rate, usual hour, slip pattern, place label), peak hours/days, goals |
| `.taskPlanning` | per-type rates and hours, avoided types, typical size, edit rate, planning/finishing hours, week shape, top 5 appointment/project/person facts |
| `.general` | a top-3 summary across sections |

Every slice also carries:
- `p`: the purpose
- `conf`: Core progress 0…1, i.e. how much to lean on the slice
- `q`: quiet hours, always included

Rules applied to every slice:
- Peak hours never fall inside quiet hours.
- Anything matching `declared.suppressed` (case-insensitive substring of a type, place label or category, habit title, or fact) is left out.
- Keys are short and empty sections are omitted, so a cold-start slice is under ~100 characters.
- Slices never contain coordinates, note IDs or note text.

Example (`.reminders`):

```json
{"avoid":["admin"],"conf":0.42,"doneH":[12,18,21],"nudge":"normal","p":"reminders","peakD":["Mon","Tue"],"peakH":[9,13,20],"q":["22:00-07:00"],"shape":"front-loaded"}
```

## Storage

- **File**: `Application Support/Core/core.json`. The folder is excluded from iCloud backup, so coordinates stay on this device, and the file is protected until first unlock.
- **Writes**: debounced by 3 s and flushed when the app goes to the background.
- **Schema**: `CoreMigrator` reads `meta.schemaVersion` and runs `steps[v]` on the raw JSON for each version bump. Every section decodes optionally, so older files open with what they have. An unreadable file, or one from a newer build, is set aside as `core.unreadable-<time>.json` and the Core starts sparse.

**Test mode**: `EvryCore.isTestMode` is true under unit tests (`XCTestConfigurationFilePath` is set) or when the app is launched with `-EvryCoreTestMode`. In test mode `EvryCore.shared` keeps everything in memory and has no location sampler, so tests that drive `TaskActions`/`HabitActions` never touch the on-device file. Core tests build their own `EvryCore` with in-memory storage, a fake locator and a fixed clock.

To change the schema:
1. Bump `CoreProfile.currentSchemaVersion`.
2. Add `steps[oldVersion]`.

## Hooks (where events come from)

| Event | Call site |
| --- | --- |
| task created | quick add (`TaskSheets`), Evry chat (`EvryActions.createTask`, `EvryChatView`), brain dump & Siri (`ContentView`), duplicate |
| edited / rescheduled in the editor | `EditTaskSheet.onDisappear`, once per visit |
| rescheduled / snoozed / completed / reopened / abandoned / restored | `TaskActions` |
| habit check-in / undo / delete | `HabitActions`; misses via the app-open sweep |
| note saved / deleted | `NoteEditorView.onDisappear`, `EvryActions.createNote`, `NoteActions.softDelete`, chat delete |
| nudge shown / accepted | Inbox overdue banner ("Move all to today") |
| mascot | Evry chat opened |
| app opened / backgrounded | `ContentView` scene phase |

Recurring-task spin-offs are not counted as new tasks.
