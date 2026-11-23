import Foundation

/// Display lines and speech tokens share an index so a spoken phrase can cross a visual line break.
struct PromptScript {
    struct Line {
        let text: String
        let start: Int
        let end: Int
    }

    let lines: [Line]
    let words: [String]

    init(_ text: String) {
        var lines: [Line] = []
        var words: [String] = []
        var fragments: [String] = []
        var length = 0
        var start = 0

        func flush() {
            guard !fragments.isEmpty else { return }
            lines.append(Line(text: fragments.joined(separator: " "), start: start, end: words.count))
            fragments.removeAll(keepingCapacity: true)
            length = 0
            start = words.count
        }

        for paragraph in text.split(whereSeparator: \.isNewline) {
            for word in paragraph.split(whereSeparator: \.isWhitespace) {
                // Long URLs and scripts without spaces must also fit below the camera.
                var rest = word
                while !rest.isEmpty {
                    let piece = String(rest.prefix(40))
                    rest = rest.dropFirst(piece.count)
                    if length + piece.count + (fragments.isEmpty ? 0 : 1) > 40 { flush() }
                    fragments.append(piece)
                    length += piece.count + (fragments.count > 1 ? 1 : 0)
                    words.append(contentsOf: Self.tokens(piece))
                }
            }
            flush()
        }
        self.lines = lines
        self.words = words
    }

    static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "")
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Consume only words from the current recognition session. A single word may match the
    /// next script word. Skipping an omission requires two adjacent words in the right order.
    func advance(_ spoken: ArraySlice<String>, from initial: Int) -> Int {
        var cursor = initial
        var i = spoken.startIndex
        while i < spoken.endIndex, cursor < words.count {
            if spoken[i] == words[cursor] {
                cursor += 1
            } else if i + 1 < spoken.endIndex {
                let limit = min(words.count - 1, cursor + 8)
                if limit > cursor + 1, let match = ((cursor + 1)..<limit).first(where: {
                    words[$0] == spoken[i] && words[$0 + 1] == spoken[i + 1]
                }) {
                    cursor = match + 2
                    i += 1
                }
            }
            i += 1
        }
        return cursor
    }
}

/// Recognition sends cumulative, revisable partials. Retain the cursor at their common
/// prefix, then re-evaluate only the changed suffix. A repeated partial consumes nothing.
struct PromptSpeechPosition {
    private var transcript: [String] = []
    private var positions: [Int]
    private(set) var furthest: Int

    init(start: Int) {
        positions = [start]
        furthest = start
    }

    mutating func update(_ phrase: String, in script: PromptScript) -> Int {
        let tokens = PromptScript.tokens(phrase)
        let common = zip(tokens, transcript).prefix(while: { $0 == $1 }).count
        guard common != tokens.count || common != transcript.count else { return furthest }
        // Reconsider the last shared token too, in case it begins a newly completed pair.
        let start = max(0, common - 1)
        positions.removeLast(positions.count - (start + 1))
        for index in start..<tokens.count {
            var next = script.advance(tokens[index...index], from: positions[index])
            if index > 0 {
                next = max(next, script.advance(tokens[(index - 1)...index], from: positions[index - 1]))
            }
            positions.append(next)
        }
        transcript = tokens
        furthest = max(furthest, positions.last ?? furthest)
        return furthest
    }
}
