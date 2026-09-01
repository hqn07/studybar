import Foundation

extension URLSession {
    /// Shared session for StudyBar's content fetches — RSS, Canvas feeds, CrossRef
    /// citations, book/cover lookups, favicons. It caps the request at 15s (resource 30s)
    /// so a slow or dropped network fails fast instead of hanging a spinner at the default
    /// 60s. AI providers keep `URLSession.shared` with their own longer budget, since model
    /// generation is legitimately slow.
    static let sb: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()
}
