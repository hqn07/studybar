import SwiftUI

/// (28) Text stats: counts, reading/speaking time, readability, target, top words.
struct WordCountView: View {
    @State private var text = ""
    @AppStorage("wcTarget") private var target = 0     // 0 = no target

    private var wordList: [String] {
        text.split { !$0.isLetter && $0 != "'" && $0 != "-" }.map { $0.lowercased() }
    }
    private var words: Int { text.split { $0.isWhitespace || $0.isNewline }.count }
    private var chars: Int { text.count }
    private var charsNoSpace: Int { text.filter { !$0.isWhitespace }.count }
    private var sentences: Int {
        max(text.isEmpty ? 0 : 1,
            text.split(whereSeparator: { ".!?".contains($0) }).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)
    }
    private var paragraphs: Int {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    private var readMin: Int { max(1, Int(ceil(Double(words) / 200.0))) }
    private var speakMin: Int { max(1, Int(ceil(Double(words) / 130.0))) }

    private var syllableTotal: Int { wordList.reduce(0) { $0 + Readability.syllables($1) } }
    private var flesch: Double {
        guard words > 0, sentences > 0 else { return 0 }
        return 206.835 - 1.015 * (Double(words) / Double(sentences)) - 84.6 * (Double(syllableTotal) / Double(words))
    }
    private var grade: Double {
        guard words > 0, sentences > 0 else { return 0 }
        return 0.39 * (Double(words) / Double(sentences)) + 11.8 * (Double(syllableTotal) / Double(words)) - 15.59
    }

    private var topWords: [(String, Int)] {
        var freq: [String: Int] = [:]
        for w in wordList where w.count > 3 && !Readability.stop.contains(w) { freq[w, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(6).map { ($0.key, $0.value) }
    }

    var body: some View {
        ModulePane(title: "Word Count") {
            HStack(spacing: 8) {
                Button { paste() } label: { Image(systemName: "doc.on.clipboard") }.help("Paste from clipboard")
                Button { text = "" } label: { Image(systemName: "trash") }.disabled(text.isEmpty)
            }
        } content: {
            VStack(spacing: 0) {
                TextEditor(text: $text)
                    .font(.body).padding(8).scrollContentBackground(.hidden).frame(minHeight: 120)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("Paste or type text here…").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                        }
                    }
                Divider()
                ScrollView {
                    VStack(spacing: 12) {
                        LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
                            stat("\(words)", "words"); stat("\(chars)", "characters"); stat("\(charsNoSpace)", "no spaces")
                            stat("\(sentences)", "sentences"); stat("\(readMin)m", "read"); stat("\(speakMin)m", "speak")
                        }
                        if !text.isEmpty {
                            readabilityCard
                            targetCard
                            if !topWords.isEmpty { topWordsCard }
                        }
                    }.padding(12)
                }
            }
        }
    }

    private var readabilityCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("READABILITY").font(.caption2.bold()).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.0f", max(0, min(100, flesch)))).font(.title3.bold())
                    Text("Flesch ease").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 1) {
                    Text("Grade \(String(format: "%.0f", max(0, grade)))").font(.title3.bold())
                    Text(Readability.label(flesch)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("TARGET").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                Stepper("\(target) words", value: $target, in: 0...20000, step: 50).font(.caption).fixedSize()
            }
            if target > 0 {
                ProgressView(value: Double(min(words, target)), total: Double(target))
                    .tint(words >= target ? .green : .accentColor)
                Text(words >= target ? "Target reached (\(words)/\(target))" : "\(target - words) words to go")
                    .font(.caption2).foregroundStyle(words >= target ? .green : .secondary)
            } else {
                Text("Set a word goal for essays and papers.").font(.caption2).foregroundStyle(.secondary)
            }
        }.padding(12).background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private var topWordsCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MOST USED WORDS").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(Array(topWords.enumerated()), id: \.offset) { _, w in
                HStack { Text(w.0); Spacer(); Text("\(w.1)×").foregroundStyle(.secondary) }.font(.caption)
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(spacing: 2) {
            Text(v).font(.title3.bold().monospacedDigit())
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(.sbSurface, in: RoundedRectangle(cornerRadius: DS.Radius.card))
    }

    private func paste() {
        if let s = NSPasteboard.general.string(forType: .string) {
            text = text.isEmpty ? s : text + "\n" + s
        }
    }
}

enum Readability {
    static func syllables(_ word: String) -> Int {
        let w = word.lowercased().filter { $0.isLetter }
        guard !w.isEmpty else { return 0 }
        let vowels = Set("aeiouy")
        var count = 0, prevVowel = false
        for c in w { let isV = vowels.contains(c); if isV && !prevVowel { count += 1 }; prevVowel = isV }
        if w.hasSuffix("e") { count = max(1, count - 1) }
        return max(1, count)
    }
    static func label(_ flesch: Double) -> String {
        switch flesch {
        case 90...: return "Very easy"
        case 70..<90: return "Easy"
        case 60..<70: return "Plain"
        case 50..<60: return "Fairly hard"
        case 30..<50: return "Hard"
        default: return "Very hard"
        }
    }
    static let stop: Set<String> = ["this","that","with","from","have","were","they","their","would","which","there","about","because","these","those","then","than","them","your","will","into","some","what","when","also","been","more","such","only","other","over","most","much"]
}
