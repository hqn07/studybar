import Foundation

/// The open-source components StudyBar is built on. Shown in Settings ▸ Open Source for
/// transparency and license attribution (MIT and Apache-2.0 both require it).
///
/// Honest note on "auto-update": these are compiled into the app at build time. A running
/// StudyBar can't swap its own libraries — versions bump when the maintainer edits
/// `project.yml` and ships a new release. So this screen shows what's *in this build* and
/// links out to each project; `scripts/deps-check.sh` is the dev-side "what's newer?" check.
struct Dependency: Identifiable, Hashable {
    let name: String
    let version: String
    let license: String        // SPDX-ish short id: "MIT", "Apache-2.0"
    let purpose: String        // what StudyBar uses it for, in one line
    let url: String            // canonical repo
    let direct: Bool           // true = StudyBar depends on it directly; false = pulled in transitively
    var id: String { name }

    /// Repo releases page — where "newer version?" actually lives.
    var releasesURL: String {
        url.hasPrefix("https://github.com/") ? url + "/releases" : url
    }
}

enum Dependencies {
    /// Curated to match `Package.resolved` + the bundled KaTeX asset. Keep versions in sync
    /// when bumping a package (or run `scripts/deps-check.sh` to see what drifted).
    static let all: [Dependency] = [
        // Direct
        .init(name: "WhisperKit", version: "0.18.0", license: "MIT",
              purpose: "On-device Whisper speech-to-text — the Voice Note engine.",
              url: "https://github.com/argmaxinc/WhisperKit", direct: true),
        .init(name: "SwiftMath", version: "1.7.3", license: "MIT",
              purpose: "Native LaTeX math typesetting — inline equations in Notes.",
              url: "https://github.com/mgriebling/SwiftMath", direct: true),
        .init(name: "KaTeX", version: "0.16.11", license: "MIT",
              purpose: "System-wide LaTeX rendering, bundled for fully-offline use.",
              url: "https://github.com/KaTeX/KaTeX", direct: true),
        // Transitive (pulled in by WhisperKit / swift-crypto)
        .init(name: "swift-transformers", version: "1.1.9", license: "Apache-2.0",
              purpose: "Tokenizers Whisper needs to encode/decode text.",
              url: "https://github.com/huggingface/swift-transformers", direct: false),
        .init(name: "swift-jinja", version: "2.4.2", license: "Apache-2.0",
              purpose: "Template rendering used by the tokenizers.",
              url: "https://github.com/huggingface/swift-jinja", direct: false),
        .init(name: "swift-crypto", version: "4.5.1", license: "Apache-2.0",
              purpose: "Hashing to verify downloaded model files.",
              url: "https://github.com/apple/swift-crypto", direct: false),
        .init(name: "swift-asn1", version: "1.7.2", license: "Apache-2.0",
              purpose: "ASN.1 support for swift-crypto.",
              url: "https://github.com/apple/swift-asn1", direct: false),
        .init(name: "swift-collections", version: "1.6.0", license: "Apache-2.0",
              purpose: "Ordered/priority collections used during decoding.",
              url: "https://github.com/apple/swift-collections", direct: false),
        .init(name: "swift-argument-parser", version: "1.8.2", license: "Apache-2.0",
              purpose: "Command-line parsing for WhisperKit's tools.",
              url: "https://github.com/apple/swift-argument-parser", direct: false),
        .init(name: "yyjson", version: "0.12.0", license: "MIT",
              purpose: "Fast JSON parsing inside WhisperKit.",
              url: "https://github.com/ibireme/yyjson", direct: false),
    ]

    static var direct: [Dependency] { all.filter(\.direct) }
    static var transitive: [Dependency] { all.filter { !$0.direct } }
    static var licenses: [String] { Array(Set(all.map(\.license))).sorted() }
}
