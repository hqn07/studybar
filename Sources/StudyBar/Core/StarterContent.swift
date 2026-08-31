import Foundation

/// Opt-in starter packs — free study resources, useful snippets, and a getting-started
/// checklist. Everything appends with de-duplication, so tapping twice is safe.
@MainActor
enum StarterContent {

    struct LinkSeed { let title: String; let url: String; let symbol: String }
    struct SnippetSeed { let keyword: String; let title: String; let body: String }

    // Curated free, no-signup study resources (general + a few per-subject).
    static let links: [LinkSeed] = [
        .init(title: "Google Scholar", url: "https://scholar.google.com", symbol: "graduationcap"),
        .init(title: "arXiv", url: "https://arxiv.org", symbol: "doc.text"),
        .init(title: "Wikipedia", url: "https://wikipedia.org", symbol: "character.book.closed"),
        .init(title: "MIT OpenCourseWare", url: "https://ocw.mit.edu", symbol: "building.columns"),
        .init(title: "OpenStax — free textbooks", url: "https://openstax.org", symbol: "books.vertical"),
        .init(title: "Khan Academy", url: "https://khanacademy.org", symbol: "play.rectangle"),
        .init(title: "Project Gutenberg", url: "https://gutenberg.org", symbol: "book"),
        .init(title: "Wolfram Alpha", url: "https://wolframalpha.com", symbol: "function"),
        .init(title: "Purdue OWL — citations", url: "https://owl.purdue.edu", symbol: "quote.opening"),
        .init(title: "Desmos Graphing", url: "https://desmos.com/calculator", symbol: "chart.xyaxis.line"),
        // per-subject
        .init(title: "Overleaf (LaTeX)", url: "https://overleaf.com", symbol: "doc.richtext"),
        .init(title: "MDN Web Docs", url: "https://developer.mozilla.org", symbol: "chevron.left.forwardslash.chevron.right"),
        .init(title: "PhET Simulations", url: "https://phet.colorado.edu", symbol: "atom"),
        .init(title: "Hemingway Editor", url: "https://hemingwayapp.com", symbol: "textformat"),
    ]

    static let snippets: [SnippetSeed] = [
        .init(keyword: ";prof", title: "Email to professor",
              body: "Dear Professor {clipboard},\n\nI hope you're doing well. I'm writing regarding \n\nThank you for your time.\n\nBest,\n"),
        .init(keyword: ";ext", title: "Extension request",
              body: "Dear Professor,\n\nI'd like to request a short extension on , currently due {date}. \n\nThank you for considering it.\n\nBest,\n"),
        .init(keyword: ";mtg", title: "Meeting notes",
              body: "# Meeting — {date}\n\n**Attendees:** \n**Agenda:** \n\n## Notes\n- \n\n## Action items\n- [ ] "),
        .init(keyword: ";lab", title: "Lab report skeleton",
              body: "# Lab Report — {date}\n\n## Objective\n\n## Materials\n\n## Method\n\n## Results\n\n## Discussion\n\n## Conclusion\n"),
        .init(keyword: ";essay", title: "Essay outline",
              body: "# {clipboard}\n\n## Introduction — thesis\n\n## Body 1\n\n## Body 2\n\n## Body 3\n\n## Conclusion\n"),
        .init(keyword: ";log", title: "Daily study log",
              body: "## {date} study log\n- Studied: \n- Time: \n- Next up: "),
    ]

    static let todos: [String] = [
        "Add your courses",
        "Import assignments from Canvas (Settings ▸ Integrations)",
        "Turn on global shortcuts (Settings ▸ Shortcuts)",
        "Try a 25-minute Pomodoro",
        "Enable the Assistant (Settings ▸ Intelligence)",
    ]

    @discardableResult
    static func addLinks(_ state: AppState) -> Int {
        var added = 0
        for l in links where !state.data.links.contains(where: { $0.url == l.url }) {
            state.data.links.append(QuickLink(title: l.title, url: l.url, symbol: l.symbol))
            added += 1
        }
        return added
    }

    @discardableResult
    static func addSnippets(_ state: AppState) -> Int {
        var added = 0
        for s in snippets where !state.data.snippets.contains(where: { $0.keyword == s.keyword || $0.title == s.title }) {
            state.data.snippets.append(Snippet(keyword: s.keyword, title: s.title, body: s.body))
            added += 1
        }
        return added
    }

    /// Getting-started tasks — seeded as Assignments (tasks with no due date) now that
    /// To-Do is merged into Assignments.
    @discardableResult
    static func addTodos(_ state: AppState) -> Int {
        var added = 0
        for t in todos where !state.data.assignments.contains(where: { $0.title == t }) {
            state.data.assignments.append(Assignment(task: t))
            added += 1
        }
        return added
    }
}
