//
//  FrequentPlaces.swift
//  Evry
//
//  The places someone visits often (work, school, the gym…), collected during
//  setup so Evry can later attach them to tasks and work out driving times.
//
//  Working out which place someone means: the on-device model (FoundationModels)
//  turns what they typed into a Maps search, MapKit searches near them, and the
//  model picks the result that best matches. What the place *is* to them (home,
//  work, the gym…) is decided by rules in `PlaceLabels`, not the model — it
//  mislabelled too often. Without the model the typed text is searched as-is.
//

import Foundation
import CoreLocation
import FoundationModels
import MapKit

// MARK: - Model

struct FrequentPlace: Codable, Identifiable, Equatable {
    var id = UUID()
    /// What kind of place it is to the person — "Work", "Gym".
    var label: String
    var name: String
    var address: String
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// What goes in a task's or event's location field — the name and the
    /// address, so Maps' directions land on the exact place.
    var locationString: String {
        if address.isEmpty || address == name { return address.isEmpty ? name : address }
        return "\(name), \(address)"
    }
}

enum FrequentPlaces {
    static let key = "frequent_places"

    /// The last decoded list, keyed by the raw data it came from. `match(for:)`
    /// runs on every task created and every title keystroke, so decode only
    /// when the stored data actually changes (any writer — including the
    /// Profile panel's @AppStorage — is picked up by the comparison).
    private static var cache: (data: Data, places: [FrequentPlace])?

    static func load() -> [FrequentPlace] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        if let cache, cache.data == data { return cache.places }
        let places = (try? JSONDecoder().decode([FrequentPlace].self, from: data)) ?? []
        cache = (data, places)
        return places
    }

    static func save(_ places: [FrequentPlace]) {
        guard let data = try? JSONEncoder().encode(places) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    /// The saved place a task or event title is about, if any — so "Go to
    /// the gym" or a "Work" event gets its location without being typed.
    /// A place named outright ("North Mass") wins; then the kind of place
    /// ("gym", "office", "go home").
    static func match(for title: String, in places: [FrequentPlace] = load()) -> FrequentPlace? {
        guard !places.isEmpty else { return nil }
        let text = " " + PlaceLabels.words(title).joined(separator: " ") + " "
        guard text.count > 2 else { return nil }

        // 1. The place's own name — or, for longer names, its first two words
        //    ("North Mass" for North Mass Boulder).
        if let named = places.first(where: { p in
            let words = PlaceLabels.words(p.name)
            var names = [words.joined(separator: " ")]
            if words.count >= 3 { names.append(words.prefix(2).joined(separator: " ")) }
            return names.contains { $0.count >= 3 && text.contains(" \($0) ") }
        }) { return named }

        // 2. The kind of place. (Store names that merely contain "home" aren't home.)
        var kindText = text
        for name in ["home depot", "home goods", "homegoods"] {
            kindText = kindText.replacingOccurrences(of: " \(name) ", with: " ")
        }
        for (label, phrases) in matchPhrases {
            guard let place = places.first(where: { $0.label == label }) else { continue }
            if phrases.contains(where: { kindText.contains(" \($0) ") }) { return place }
            // The title is just the kind ("Work", "Gym").
            if kindText.trimmingCharacters(in: .whitespaces) == label.lowercased() { return place }
        }

        // 3. Any other label the person gave a place ("Barber", "Dentist").
        let generic: Set<String> = ["location", "store", "work", "home", "gym", "school", "grocery store"]
        return places.first { p in
            let label = PlaceLabels.words(p.label).joined(separator: " ")
            return !generic.contains(label) && label.count >= 3 && text.contains(" \(label) ")
        }
    }

    /// Phrases (whole words) that put a title at each kind of saved place.
    /// "Work" is only matched as a place ("at work", "the office"), never the
    /// verb ("work on the report").
    private static let matchPhrases: [(label: String, phrases: [String])] = [
        ("Gym", ["gym", "workout", "work out", "lift", "lifting", "leg day", "climb", "climbing",
                 "boulder", "bouldering", "crossfit", "yoga", "pilates", "spin class", "exercise"]),
        ("Work", ["at work", "to work", "from work", "for work", "leave work", "work shift", "shift",
                  "office", "commute", "workday", "work day"]),
        ("Home", ["go home", "head home", "get home", "at home", "back home", "home"]),
        ("School", ["school", "class", "classes", "campus", "lecture", "college", "university"]),
        ("Grocery store", ["grocery", "groceries", "grocery shopping", "supermarket"]),
    ]
}

// MARK: - Resolving what someone typed

/// One place Maps found that might be what the person meant.
struct PlaceCandidate: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let address: String
    /// Maps' category for the place, if it has one.
    let category: MKPointOfInterestCategory?
    let coordinate: CLLocationCoordinate2D
    /// Straight-line distance from the person, in metres, if known.
    let distance: CLLocationDistance?
    /// A plain street address rather than a business or venue — likely a house.
    let isAddress: Bool

    /// A plain description of the kind of place ("fitness center"), if known.
    var kind: String? { category.map(PlaceLabels.describe) }

    static func == (a: PlaceCandidate, b: PlaceCandidate) -> Bool { a.id == b.id }

    func place(label: String) -> FrequentPlace {
        FrequentPlace(label: label, name: name, address: address,
                      latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// What Evry takes a found place to be, and what (if anything) it checks.
struct PlaceRole: Equatable {
    enum Check: Equatable {
        /// Confident — just "is that the one?".
        case none
        /// A house address: "Is that your home?"
        case home
        /// Anything else: "Is that where you work?"
        case work
    }
    var label: String
    var check: Check

    static let fallbackLabel = "Location"
}

enum PlaceResolution {
    /// Candidates to confirm, best guess first. `stated` is the kind of place
    /// the person said it is, if they did ("my gym, …").
    case found(stated: String?, candidates: [PlaceCandidate])
    /// A kind of place with no name ("work") — Evry needs to ask which one.
    case needsName(label: String)
    case notFound
}

/// What the person meant by a typed reply to Evry's check about a place.
enum PlaceReply: Equatable {
    case yes, no, wrongPlace
    /// They said what it is instead ("no, that's just a store I go to").
    case kind(String)
}

@Generable(description: "How to find the place a person means from a short phrase")
private struct PlaceGuess {
    @Guide(description: "An Apple Maps search that finds the specific place they mean: a business or venue name, a landmark, or a street address, exactly as they wrote it, without words like 'my' or 'the'. Empty if they gave only a generic kind of place with no name or address, such as just 'work', 'school', 'the gym' or 'home'.")
    var searchQuery: String

    @Guide(description: "When searchQuery is empty: the kind of place they named, as a short sentence-case label such as Work, School, Gym or Home. Otherwise exactly: Location")
    var label: String
}

@Generable(description: "Which search result is the place the person means")
private struct PlacePick {
    @Guide(description: "The number of the result whose name best matches what the person typed; if several match, the nearest of those.")
    var index: Int
}

@Generable(description: "What a person's reply means, when asked whether a place is their home or work")
private struct PlaceReplyMeaning {
    @Guide(description: "One of: yes (it is), no (it isn't, with no other detail), wrong (they mean a different place altogether), kind (they said what the place is to them)")
    var meaning: String

    @Guide(description: "When meaning is kind: what it is to them as a short sentence-case label — Home, Work, Gym, School, Store, Grocery store, Coffee shop, Church, Doctor, Friend's place and the like. Use Grocery store only if they said grocery or supermarket. Otherwise exactly: Location")
    var label: String
}

enum PlaceResolver {
    /// Works out which real place `input` refers to, searching near `near`.
    /// `pendingLabel` is set when the person is answering "which work is it?",
    /// so the input is the place's name and the label is already known.
    static func resolve(_ input: String, near: CLLocationCoordinate2D?,
                        pendingLabel: String? = nil) async -> PlaceResolution {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        var query = text
        var modelLabel: String?

        if pendingLabel == nil, let guess = await guess(text) {
            let q = guess.searchQuery.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty { query = q }
            else {
                let l = guess.label.trimmingCharacters(in: .whitespaces)
                modelLabel = l.isEmpty || l == PlaceRole.fallbackLabel ? nil : l
                query = ""
            }
        }

        // The kind they said, from the words that aren't the place's name
        // ("my gym, Planet Fitness" → Gym). Rules, not the model, decide this.
        let stated = pendingLabel ?? PlaceLabels.statedKind(in: text, excluding: query)
        if query.isEmpty {
            // Only a kind of place ("work", "the gym"): ask which one.
            if let label = stated ?? modelLabel { return .needsName(label: label) }
            query = text
        }

        let candidates = await search(query, near: near, typedAddress: looksLikeAddress(text))
        guard !candidates.isEmpty else { return .notFound }
        return .found(stated: stated, candidates: await rank(candidates, for: text))
    }

    /// Reads a typed reply to "Is that your home / where you work?". Clear
    /// words are read by rule; anything else goes to the model.
    static func interpretReply(_ reply: String) async -> PlaceReply {
        let text = reply.lowercased()
        let words = PlaceLabels.words(text)
        let first = words.first ?? ""
        if ["wrong", "different", "another"].contains(where: words.contains)
            || text.contains("not that one") || text.contains("not the right") {
            return .wrongPlace
        }
        if let kind = PlaceLabels.statedKind(in: text, excluding: "") { return .kind(kind) }
        if ["yes", "yeah", "yep", "yup", "sure", "correct", "right", "yea", "ya"].contains(first)
            || text.hasPrefix("it is") || text.hasPrefix("that's it") {
            return .yes
        }
        if ["no", "nope", "nah", "not"].contains(first) && words.count <= 2 { return .no }

        guard EvryAssistant.isAvailable else { return .kind(PlaceRole.fallbackLabel) }
        let session = LanguageModelSession(instructions: """
            Evry asked someone whether a place is their home or where they work. \
            Read their reply. Never invent a kind of place they didn't describe.
            """)
        guard let m = try? await session.respond(to: "Their reply: \(reply)",
                                                 generating: PlaceReplyMeaning.self).content
        else { return .kind(PlaceRole.fallbackLabel) }
        switch m.meaning.lowercased() {
        case "yes": return .yes
        case "no": return .no
        case "wrong": return .wrongPlace
        default:
            var label = m.label.trimmingCharacters(in: .whitespaces)
            // Strict: only a grocery store if they actually said so.
            if label.lowercased().contains("grocery") && !text.contains("grocer") && !text.contains("supermarket") {
                label = "Store"
            }
            return .kind(label.isEmpty ? PlaceRole.fallbackLabel : label)
        }
    }

    // MARK: Steps

    private static func guess(_ text: String) async -> PlaceGuess? {
        guard EvryAssistant.isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
            You help someone list the places they visit often, for a planner app. \
            They type a short phrase: a place's name ("North Mass", "Kroger"), an \
            address ("123 Main St"), a kind of place ("work", "the gym"), or a \
            mix ("my gym, Planet Fitness"). Give the map search that would find \
            the specific place. Never invent a name they didn't give.
            """)
        return try? await session.respond(to: "They typed: \(text)", generating: PlaceGuess.self).content
    }

    private static func search(_ query: String, near: CLLocationCoordinate2D?,
                               typedAddress: Bool) async -> [PlaceCandidate] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = [.pointOfInterest, .address]
        if let near {
            request.region = MKCoordinateRegion(center: near, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
        guard let response = try? await MKLocalSearch(request: request).start() else { return [] }
        let origin = near.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let found = response.mapItems.prefix(8).map { item -> PlaceCandidate in
            let c = item.location.coordinate
            return PlaceCandidate(
                name: item.name ?? query,
                address: item.address?.shortAddress ?? item.address?.fullAddress ?? "",
                category: item.pointOfInterestCategory,
                coordinate: c,
                distance: origin?.distance(from: CLLocation(latitude: c.latitude, longitude: c.longitude)),
                // No business category and they typed a street address: a house.
                isAddress: typedAddress && item.pointOfInterestCategory == nil)
        }
        // Nearest first: that's usually the one they mean.
        return found.sorted { ($0.distance ?? .greatestFiniteMagnitude) < ($1.distance ?? .greatestFiniteMagnitude) }
    }

    /// Moves the candidate the model thinks fits best to the front.
    private static func rank(_ candidates: [PlaceCandidate], for text: String) async -> [PlaceCandidate] {
        guard candidates.count > 1, EvryAssistant.isAvailable else { return candidates }
        let list = candidates.enumerated().map { i, c in
            var line = "\(i + 1). \(c.name)"
            if let kind = c.kind { line += " (\(kind))" }
            if !c.address.isEmpty { line += ", \(c.address)" }
            if let d = c.distance { line += ", \(Int((d / 1000).rounded())) km away" }
            return line
        }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            Pick which map search result is the place a person means. Prefer the \
            result whose name matches what they typed, then the nearest.
            """)
        guard let pick = try? await session.respond(
            to: "They typed: \(text)\n\nResults:\n\(list)", generating: PlacePick.self).content,
              (1...candidates.count).contains(pick.index) else { return candidates }
        var ranked = candidates
        ranked.insert(ranked.remove(at: pick.index - 1), at: 0)
        return ranked
    }

    /// "123 Main St", "4410 N College Ave" — a house number then a street.
    private static func looksLikeAddress(_ text: String) -> Bool {
        text.range(of: #"^\s*\d+[a-zA-Z]?\s+\S+"#, options: .regularExpression) != nil
    }
}

// MARK: - Labelling rules

/// Decides what a place is to someone by rule, not by the model — most
/// places people list are home, work or the gym, so those are assumed, and
/// stores are only ever named for an exact chain match or when the person
/// says so.
enum PlaceLabels {
    /// Words people use for a kind of place → its label. Checked in order;
    /// phrases are matched as whole words.
    private static let kindWords: [(words: [String], label: String)] = [
        (["grocery", "groceries", "grocer", "supermarket"], "Grocery store"),
        (["gym", "workout", "fitness", "crossfit", "climbing", "bouldering", "yoga", "pilates"], "Gym"),
        (["home", "house", "apartment", "apt", "condo", "my place"], "Home"),
        (["work", "office", "job", "workplace", "employer"], "Work"),
        (["school", "college", "university", "campus", "class", "classes"], "School"),
        (["church", "temple", "mosque", "synagogue"], "Place of worship"),
        (["doctor", "doctors", "clinic"], "Doctor"),
        (["dentist"], "Dentist"),
        (["barber", "barbershop", "salon", "haircut"], "Barber"),
        (["coffee", "cafe"], "Coffee shop"),
        (["restaurant"], "Restaurant"),
        (["park"], "Park"),
        (["library"], "Library"),
        (["daycare"], "Daycare"),
        (["friend", "friends", "friend's"], "Friend's place"),
        (["parents", "parents'", "mom's", "dad's", "family"], "Family"),
        (["store", "shop", "shopping", "mall", "market"], "Store"),
    ]

    /// Gyms by name, for when Maps has no category for them.
    private static let gymNameWords = ["gym", "fitness", "crossfit", "climbing", "boulder", "bouldering",
                                       "yoga", "pilates", "ymca", "orangetheory", "f45", "barre",
                                       "athletic club", "health club", "workout"]
    private static let schoolNameWords = ["school", "university", "college", "academy", "elementary",
                                          "middle school", "high school", "campus"]

    /// Exact grocery chains — the only places labelled Grocery store by name.
    private static let groceryChains = [
        "kroger", "whole foods", "trader joe", "aldi", "publix", "safeway", "wegmans", "h-e-b", "heb",
        "food lion", "stop & shop", "albertsons", "sprouts", "harris teeter", "hy-vee", "fresh market",
        "fresh thyme", "piggly wiggly", "winn-dixie", "lidl", "save a lot", "market basket", "shoprite",
        "ralphs", "vons", "fred meyer", "king soopers", "jewel-osco", "schnucks", "dierbergs",
        "hannaford", "raley's", "stater bros", "food 4 less", "winco", "grocery outlet", "meijer",
        "giant eagle", "giant food", "marsh", "fiesta mart", "smart & final", "natural grocers",
    ]
    /// Big general stores.
    private static let generalStores = [
        "walmart", "target", "costco", "sam's club", "bj's wholesale", "dollar general", "dollar tree",
        "family dollar", "cvs", "walgreens", "home depot", "lowe's", "best buy", "ikea", "kohl's",
    ]

    /// What `c` is to the person: what they said, else what the place
    /// clearly is, else assume work and ask. Home and work are only asked
    /// about until one has been saved — once confirmed, never again.
    static func role(for c: PlaceCandidate, stated: String?, saved: Set<String> = []) -> PlaceRole {
        if let stated { return PlaceRole(label: stated, check: .none) }
        if c.isAddress {
            return saved.contains("Home")
                ? PlaceRole(label: PlaceRole.fallbackLabel, check: .none)
                : PlaceRole(label: "Home", check: .home)
        }
        let name = c.name.lowercased()
        if c.category == .fitnessCenter || containsWord(name, gymNameWords) {
            return PlaceRole(label: "Gym", check: .none)
        }
        if c.category == .school || c.category == .university || containsWord(name, schoolNameWords) {
            return PlaceRole(label: "School", check: .none)
        }
        if groceryChains.contains(where: { name.hasPrefix($0) }) {
            return PlaceRole(label: "Grocery store", check: .none)
        }
        if generalStores.contains(where: { name.hasPrefix($0) }) {
            return PlaceRole(label: "Store", check: .none)
        }
        // Offices, companies and everything else: most likely where they work.
        if saved.contains("Work") { return PlaceRole(label: PlaceRole.fallbackLabel, check: .none) }
        return PlaceRole(label: "Work", check: .work)
    }

    /// The kind of place named in `text`, ignoring the words of `excluding`
    /// (the place's own name, so "Whole Foods Market" isn't read as "market").
    static func statedKind(in text: String, excluding name: String) -> String? {
        var rest = text.lowercased()
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if !n.isEmpty { rest = rest.replacingOccurrences(of: n, with: " ") }
        for entry in kindWords where containsWord(rest, entry.words) {
            return entry.label
        }
        return nil
    }

    static func words(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { !$0.isEmpty }
    }

    /// Whole-word (or whole-phrase) match.
    private static func containsWord(_ text: String, _ candidates: [String]) -> Bool {
        let padded = " " + words(text).joined(separator: " ") + " "
        return candidates.contains { padded.contains(" \($0) ") }
    }

    /// "MKPOICategoryFitnessCenter" → "fitness center".
    nonisolated static func describe(_ category: MKPointOfInterestCategory) -> String {
        let raw = category.rawValue.replacingOccurrences(of: "MKPOICategory", with: "")
        var words = ""
        for ch in raw {
            if ch.isUppercase && !words.isEmpty { words.append(" ") }
            words.append(ch)
        }
        return words.lowercased()
    }
}
