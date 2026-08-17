# Evry — Simulated Beta Test Report

**Method & honesty note.** This is a *code-traced* simulated beta test: I read the actual SwiftUI views / models / services and traced, step by step, what each persona's realistic action sequence would do. I could **not** run the app live — the project's signing is currently broken (expired iOS provisioning profile + login error `-1009`), and the Simulator has **no microphone**, so **voice/Brain-Dump dictation and on-device Apple-Intelligence extraction could not be exercised at runtime**. Those flows are traced from code and flagged as "not runtime-verified." Everything else is grounded in specific files/lines.

Legend for severity: **Blocker** (stops a real beta user cold) · **High** · **Medium** · **Low** · **Polish**.

---

## 🔧 FIX FIRST — Top 10 (prioritized)

| # | Issue | Severity | Why it's first |
|---|-------|----------|----------------|
| 1 | **Vertical scrolling is broken in the Timeline layout — which is the *default* Inbox view** (`SwipeActionRow`'s per-row `DragGesture` swallows the inner ScrollView's pan) | Blocker | Every user with more tasks than fit on one screen can't scroll their day. It's the first screen they land on. |
| 2 | **Streak mechanics ship in Profile + Guide Tour** (`🔥 X-day streak`, `Best streak`, "Complete a task to start a streak!") | High | Directly violates Evry's stated core principle (no streaks / no bait-to-reopen). This is the app's #1 product risk for OCD/ADHD users. |
| 3 | **No Reduce Motion support** — breathing orbs, sonar rings, pulsing ring all `repeatForever` regardless of the system setting | High (a11y) | Target audience explicitly includes animation/sensory sensitivity. |
| 4 | **No Dynamic Type support** — ~370 hard-coded `.font(.system(size:))`, zero `ScaledMetric`/`dynamicTypeSize` | High (a11y) | Low-vision / large-text users get a fixed, tiny UI. |
| 5 | **Icon-only controls lack VoiceOver labels** (Pomodoro ✕/Reset/Skip, Brain Dump ✕, calendar arrows, checkboxes, loop steppers) — ~8 `accessibilityLabel`s in the whole app | High (a11y) | VoiceOver users can't identify core buttons. |
| 6 | **Brain Dump without Apple Intelligence splits on newlines** → a dictated paragraph (no newlines) becomes **one giant task** | High | Hits exactly the voice-first users on non-AI devices — a core Evry use case. |
| 7 | **"Weekend" means different days depending on entry point, and is surprising on Sundays** (`nextWeekend()` jumps 13 days on Sun; reschedule menu's "This Weekend" gives 6 days) | Medium | Inconsistent date math undermines trust for schedule-heavy users. |
| 8 | **Onboarding asks for Location permission as its own step** with no obvious skip until after a denial | Medium | Premature/opaque permission ask = friction + distrust for first-timers. |
| 9 | **Timeline long-press stack double-fires** (reschedule at 0.3s *then* multiselect at 0.5s) so the reschedule popover flashes before selection | Low | Confusing micro-interaction on the default screen. |
| 10 | **No mic-permission recovery path** — denial shows static "Enable microphone in Settings" with no deep link | Low | Voice-first users who tap "Don't Allow" are stuck with no guidance. |

Items **1–2** are the ones that matter most for this product specifically. **3–5** unblock the accessibility persona entirely. **6** unblocks voice users on older hardware.

---

## Persona panel (15)

Chosen so each behavior pattern exposes *different* code paths — not cosmetic variation.

| # | Persona | Trait | Goal | Stress-test quirk |
|---|---------|-------|------|-------------------|
| P1 | **Maya, 24** | ADHD, low onboarding patience | Just wants to start capturing | Skips/mashes onboarding, ignores tips |
| P2 | **Deborah, 41** | OCD, needs reassurance + privacy | Rigid daily structure | Reads every screen; scrutinizes permissions |
| P3 | **Theo, 30** | Hyperfocus, power user | Never lose a task | 200+ tasks piled up; scrolls fast |
| P4 | **Priya, 36** | Perfectionism about categorization | Everything filed correctly | Obsessively edits/re-tags tasks & notes |
| P5 | **Sam, 19** | ADHD racing thoughts | Catch stray thoughts by voice | Voice-only Brain Dump, never types |
| P6 | **Lena, 45** | Voice-first, **older iPhone (no Apple Intelligence)** | Brain dump a to-do list aloud | Dictates a run-on paragraph |
| P7 | **Marcus, 28** | Task-switching mid-flow | Fast triage | Swipe-to-schedule with imprecise diagonal swipes |
| P8 | **Nadia, 33** | Rigid checklist need | Schedule everything precisely | Tests weekend/next-week/edge dates on different weekdays |
| P9 | **Owen, 22** | Rich-text note-taker | Structured notes | Heavy formatting; bold/lists; reopen/edit |
| P10 | **Bea, 38** | Voice capture → notes | Long-form thoughts to a note | Brain Dump (voice) into Notes mode |
| P11 | **Chris, 27** | Distrusts gamification | Healthy tool, no manipulation | Actively hunts for streak/bait mechanics |
| P12 | **Fatima, 31** | Completion-motivated | Feel done and put it down | Runs the complete → celebrate → leave loop repeatedly |
| P13 | **Ravi, 52** | **VoiceOver + Dynamic Type XXL + Reduce Motion** | Use the app non-visually / large text | Full accessibility stack on |
| P14 | **Jordan, 26** | Impatient, interrupts flows | Quick capture | Rage-taps, backgrounds/resumes mid-action |
| P15 | **Elle, 35** | Sensory sensitivity to motion/color | Calm experience | Watches for flashing/perpetual motion; dark mode |

---

## 1. Highest-confidence issues (found independently by 2+ personas)

Ranked by (personas hit × severity).

1. **Timeline scroll broken [EV-001]** — Blocker — hit by **P3, P4, P7, P12, P14** (anyone whose day list overflows). The default `inbox_layout` is `.timeline` (`InboxView.swift:51`); `TimelineDayPage`'s rows are wrapped in `SwipeActionRow`, whose `.simultaneousGesture(DragGesture(minimumDistance:4))` (`Components.swift:548`) intercepts the inner `ScrollView`'s vertical pan.
2. **Streak mechanics contradict the design principle [EV-002]** — High — flagged by **P11, P12, P2, P15**. `ProfileView.swift:233/287/325-326`, `GuideTourView.swift:51`, `TaskLogic.swift:26/76-104`.
3. **Perpetual animation / no Reduce Motion [EV-003]** — High — hit by **P13, P15** (and annoyance for P2). `BreathingOrb` (`BrainDumpSheet.swift`), Pomodoro ring breath (`PomodoroView.swift`), sonar rings — all `.repeatForever`.
4. **No Dynamic Type [EV-004]** — High — **P13**, degraded for **P2/P15**. Global.
5. **Brain Dump newline-split fallback [EV-006]** — High — **P5, P6** (voice users on non-AI devices). `BrainDumpSheet.swift` `analyzeTasks()` non-AI branch.
6. **Weekend date drift/surprise [EV-007]** — Medium — **P8, P7**. `TaskParsing.nextWeekend()` vs `TaskActions.nextWeekdayDate(6)`.

---

## 2. Blockers

- **[EV-001] Timeline vertical scroll dead over task rows.** Default view. Repro: add ~10 tasks due today → open Inbox (Timeline) → drag up starting on a task → nothing scrolls; only drags on blank areas move. *Known/in-progress per project history; still the #1 functional blocker for a beta.*
- No crashes or data-loss paths were found in tracing. SwiftData writes (`context.insert`, toggles) are straightforward; no force-unwraps on user data in the hot paths reviewed. (Not runtime-verified.)

---

## 3. Patterns by feature area

**Onboarding (P1, P2)**
- Location permission is a full onboarding stage (`SetupFlowView.swift`), asked before the user has created anything. P2 (privacy-scrutinizing) reads this as "why does a to-do app want my location?" and there's no in-context explanation. P1 wants to skip but the **Skip** affordance is only on non-location stages (`stage != .location`, `SetupFlowView.swift:95`); on the location step a `notDetermined` user only gets "Enable location," and "Continue without location" appears **only after** a denial.
- Guide Tour advertises "**Track your streaks**" (`GuideTourView.swift:51`) — sets an expectation that conflicts with the product's own philosophy.

**Brain Dump (P5, P6, P10)** — *voice paths not runtime-verified (no mic in Simulator).*
- With Apple Intelligence unavailable (`SystemLanguageModel.default.isAvailable == false`), extraction falls back to splitting `input` on **newlines**. Dictation produces a single unbroken string → **one massive task** (EV-006). P6 is the exact victim.
- Mic denial gives no recovery path/deep link (EV-010).
- Priority over-labeling was **just addressed** this session (sparing-by-default + adapts to the user's own priority habit) — verify it holds (EV-016, likely resolved).
- Positives worth keeping: empty submit is correctly disabled (`Analyze` disabled when `inputEmpty`); the closure/"Off your mind" beat + auto-dismiss is a genuinely healthy disengagement pattern.

**Swipe-to-Schedule (P7, P8)**
- `ScheduleSwipeCard` (add-task) is locked while a location dropdown is open (good). Diagonal/imprecise swipes: axis handling exists, but P7's sloppy gestures need runtime confirmation.
- Date keywords are centralized (`resolveDateKeyword`) so typed vs swipe generally agree — good. The exception is the weekend rule (EV-007).

**Notes (P9, P10)**
- Notes use a **custom UIKit `NoteBodyEditor`** (RTFD). Rich-text is powerful but the custom editor is the highest VoiceOver/Dynamic-Type risk surface (EV-004/EV-005) and couldn't be runtime-verified.
- Brain Dump → Notes path exists and is shared cleanly with the tasks path.

**Rewards / Profile (P11, P12)**
- Streaks + "best streak" + "Complete a task to start a streak!" (guilt-tinged empty state) are present (EV-002). This is the single biggest deviation from stated principles.
- The completion animations themselves (checkbox burst, accomplishments summary) are celebratory-then-quiet and do **not** nag or push re-opening — those are fine and on-brand.

**Task Inbox (P3, P4)**
- Beyond EV-001, the timeline row long-press stack double-fires (EV-009). Reorder is handle-only in some builds; the reverted build uses whole-row holds.

**Accessibility (P13)** — see §6.

**Performance (P3)**
- `computeStats` runs over all tasks each Profile render (O(n), fine to ~thousands). `rebuildDotCache` queries EventKit across **±30 months** on calendar changes — acceptable because cached, but worth watching on first paint for heavy calendars. No obvious O(n²).

---

## 4. Patterns by persona type

- **Power users (P3, P4):** both blocked by EV-001 immediately; both notice streaks. No hard perf wall found in tracing at ~200 tasks, but EV-001 makes volume unusable regardless.
- **Voice-first (P5, P6, P10):** all three depend on flows that can't be runtime-verified here; P6 specifically breaks on the newline-split fallback.
- **Reward-sensitive (P11, P12):** both surface EV-002 as the defining trust issue; both approve of the completion→closure loop.
- **Accessibility/sensory (P13, P15):** blocked/degraded by EV-003/004/005; P15 also flags the every-second numeric roll (EV-012) and constant orb motion as agitating.
- **Onboarding (P1, P2):** both stall at the location step for opposite reasons (impatience vs scrutiny).

---

## 5. Design-principle violations (call-outs — weigh these above average polish)

- **[EV-002] Streaks are the anti-pattern the product explicitly rejects.** `🔥 X-day streak`, `Best streak`, and "Complete a task to start a streak!" create exactly the loss-aversion / don't-break-the-chain pressure that harms OCD/ADHD users and baits daily re-opening. **Recommendation:** remove streak counters and the streak empty-state copy; if a "consistency" surface is wanted, use a **non-punitive, non-counted** reflection (e.g., "You've had some good days lately") with no number to protect. Also fix the Guide Tour line.
- **[EV-012] Perpetual motion as ambient state.** Breathing orbs / pulsing ring run forever while a screen is open. For a calm, anti-agitation tool this is borderline even before accessibility — gate all `repeatForever` motion behind `@Environment(\.accessibilityReduceMotion)` and consider making the *idle* state still rather than breathing.
- **[EV-008] Front-loaded permission asks (location).** Asking before value is shown erodes the "reduce friction/decision load" goal. Defer location to first actual use (adding a place to a task).
- **Positive (keep):** the Brain Dump closure beat and the completion animations that celebrate then get out of the way are exactly right — don't let a rewards redesign regress them.

---

## 6. Accessibility findings (P13, and P15 for motion)

- **[EV-003] Reduce Motion ignored.** No `accessibilityReduceMotion` anywhere. `repeatForever` animations: `BreathingOrb` breath + sonar (`BrainDumpSheet.swift`), Pomodoro ring breath (`PomodoroView.swift`). Provide static/opacity-only fallbacks.
- **[EV-004] Dynamic Type ignored.** ~370 fixed `.font(.system(size:))`; no `ScaledMetric`/relative text styles. Nothing scales at larger accessibility sizes; fixed frames (e.g., 22pt checkboxes, 30pt header icons, 260pt ring) will clip scaled text.
- **[EV-005] Missing VoiceOver labels.** Only ~8 `accessibilityLabel`s app-wide. Unlabeled: Pomodoro ✕/Reset/Skip/loop ±, Brain Dump ✕/back, calendar month/year nav arrows, task checkboxes, note formatting controls. Many icon buttons will read as "Button" with no meaning.
- **[EV-013] Custom UIKit note editor** (`NoteBodyEditor`) needs explicit VoiceOver/rotor + Dynamic Type verification — custom `UITextView` subclasses often drop trait scaling.
- **[EV-014] Color-only status.** Priority (danger/warning/success) and date-category chips are distinguished largely by color; verify contrast in both schemes and add text/shape redundancy for color-blind users (`Theme.swift` chip colors).

---

## 7. Quick wins vs. deeper fixes

**Quick wins (< ~1 hour each)**
- EV-002 (partial): delete streak counters + "Complete a task to start a streak!" copy + Guide Tour "streaks" line. (Removing display is fast; deciding the replacement is the product call.)
- EV-005: add `accessibilityLabel`s to the icon-only buttons.
- EV-009: collapse the two stacked timeline long-presses into one press-duration handler (or gate the 0.3s reschedule so it doesn't fire when it becomes a 0.5s multiselect).
- EV-010: point the mic-denied text at `UIApplication.openSettingsURLString`.
- EV-007: make reschedule "This Weekend" call the shared `nextWeekend()` and reconsider the Sunday rule so all three entry points agree.
- EV-008: move the location ask out of onboarding (or add an explicit "Skip" + one-line rationale on that step).

**Deeper fixes (design/engineering)**
- EV-001: the timeline scroll vs. per-row swipe conflict — needs a swipe mechanism that doesn't fight the ScrollView (e.g., native `List` `.swipeActions`, or a UIKit-hosted collection) rather than the custom `SwipeActionRow` `DragGesture`. *(History: tap-only rows fixed scrolling but lost swipe; this is the real trade to resolve.)*
- EV-003/EV-004: retrofit Reduce Motion + Dynamic Type across the app (systemic).
- EV-006: give the non-AI Brain Dump fallback a real sentence/clause splitter instead of newline-only.
- EV-002 (full): design a healthy consistency/reflection surface to replace streaks.

---

## Appendix: what could NOT be verified (guardrail)

- **Live build/run** — blocked by expired provisioning + `-1009` login. All findings are static traces.
- **Voice capture & on-device AI extraction** (P5, P6, P10) — no Simulator mic; `SystemLanguageModel` availability is device-dependent. Behavior inferred from code.
- **Real gesture arbitration** (EV-001 severity, diagonal swipes) — inferred from gesture code; a device pass would confirm exact thresholds.
- **VoiceOver/Dynamic Type actual output** — inferred from absence of the corresponding APIs, not from a live a11y audit.

Full per-issue log: `beta-test-issues.csv`.
