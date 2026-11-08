import Foundation

enum GreetingPeriod: Int, CaseIterable {
    case morning, afternoon, evening, night
    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        case 17..<22: self = .evening
        default: self = .night
        }
    }
    var symbol: String {
        switch self {
        case .morning: "sunrise"
        case .afternoon: "sun.max"
        case .evening: "sunset"
        case .night: "moon.stars"
        }
    }
}

enum GreetingText {
    static let languages = ["English", "Español", "Français", "日本語", "हिन्दी"]
    static let phrases = [
        ["Good morning", "Good afternoon", "Good evening", "Good night"],
        ["Buenos días", "Buenas tardes", "Buenas tardes", "Buenas noches"],
        ["Bonjour", "Bon après-midi", "Bonsoir", "Bonne nuit"],
        ["おはようございます", "こんにちは", "こんばんは", "おやすみなさい"],
        ["सुप्रभात", "शुभ दोपहर", "शुभ संध्या", "शुभ रात्रि"]
    ]
    static func cleanName(_ value: String) -> String? {
        let text = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.illegalCharacters.contains($0)
        }.prefix(48).map(String.init).joined()).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
    static func text(period: GreetingPeriod, language: Int, name: String?) -> String {
        let index = max(0, min(language, phrases.count - 1))
        let phrase = phrases[index][period.rawValue]
        guard let name = name.flatMap(cleanName) else { return phrase + "." }
        return index == 3 ? "\(phrase)、\(name)さん。" : "\(phrase), \(name)."
    }
}
