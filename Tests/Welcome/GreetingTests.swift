import Foundation

@main struct GreetingTests {
    static func main() {
        let samples: [(Int, GreetingPeriod)] = [(0,.night),(4,.night),(5,.morning),(11,.morning),(12,.afternoon),(16,.afternoon),(17,.evening),(21,.evening),(22,.night),(23,.night)]
        for (hour, expected) in samples {
            precondition(GreetingPeriod(hour: hour) == expected, "Wrong greeting at hour \(hour)")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let formatter = ISO8601DateFormatter()
        let localMorning = formatter.date(from: "2026-10-21T10:30:00-05:00")!
        precondition(GreetingPeriod(hour: calendar.component(.hour, from: localMorning)) == .morning)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        precondition(GreetingPeriod(hour: calendar.component(.hour, from: localMorning)) == .night)
        precondition(GreetingText.text(period: .morning, language: 0, name: " Alex\n") == "Good morning, Alex.")
        precondition(GreetingText.text(period: .afternoon, language: 0, name: nil) == "Good afternoon.")
        precondition(GreetingText.text(period: .evening, language: 3, name: "美咲") == "こんばんは、美咲さん。")
        precondition(GreetingText.cleanName("\n\t ") == nil)
        precondition(GreetingText.cleanName(String(repeating: "a", count: 500))?.count == 48)
        precondition(GreetingText.text(period: .night, language: 100, name: nil).contains("शुभ"))
        print("Welcome checks passed: local time boundaries, time-zone changes, signed-out greetings, Unicode names and bounded display text.")
    }
}
