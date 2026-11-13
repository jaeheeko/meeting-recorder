import Foundation
import EventKit

/// 회의와 겹치는 캘린더 일정 한 건. session.json 과 전사본 헤더에 그대로 기록한다.
struct CalEvent: Codable {
    var title: String
    var start: String          // "yyyy-MM-dd HH:mm"
    var end: String
    var attendees: [String]    // "이름 <이메일>"
    var organizer: String
    var location: String
    var videoLink: Bool        // 화상회의 링크가 있는가(대면/화상 판단용)
    var notes: String          // 앞 1,000자
    var overlapSeconds: Int
}

enum CalendarLookup {
    static func requestAccess() {
        let store = EKEventStore()
        store.requestFullAccessToEvents { ok, err in
            log("캘린더 권한: \(ok)\(err.map { " (\($0))" } ?? "")")
        }
    }

    private static let fmt: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; return f }()

    /// 녹음 구간(시작 10분 전 ~ 종료)과 겹치는 일정 중 겹침이 큰 순으로 최대 3개. 권한이 없거나 일정이 없으면 빈 배열.
    static func events(start: Date, end: Date) -> [CalEvent] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        let store = EKEventStore()
        let from = start.addingTimeInterval(-600)
        let pred = store.predicateForEvents(withStart: from, end: end, calendars: nil)
        var out: [CalEvent] = []
        for e in store.events(matching: pred) {
            if e.isAllDay { continue }
            if e.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) == true { continue }
            let ov = Int(min(e.endDate, end).timeIntervalSince(max(e.startDate, start)))
            let early = Int(min(e.endDate, end).timeIntervalSince(max(e.startDate, from)))
            guard early > 0 else { continue }
            let hay = [e.location ?? "", e.notes ?? "", e.url?.absoluteString ?? ""].joined(separator: " ").lowercased()
            let video = ["meet.google.com", "zoom.us", "teams.microsoft", "webex", "slack.com/huddle"].contains { hay.contains($0) }
            let atts = (e.attendees ?? []).map { a -> String in
                let mail = a.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
                return "\(a.name ?? "") <\(mail)>"
            }
            out.append(CalEvent(title: e.title ?? "", start: fmt.string(from: e.startDate), end: fmt.string(from: e.endDate),
                                attendees: atts, organizer: e.organizer?.name ?? "", location: e.location ?? "",
                                videoLink: video, notes: String((e.notes ?? "").prefix(1000)), overlapSeconds: max(ov, 0)))
        }
        return Array(out.sorted { $0.overlapSeconds > $1.overlapSeconds }.prefix(3))
    }

    static func render(_ evs: [CalEvent]) -> String {
        if evs.isEmpty { return "캘린더 일정 없음" }
        return evs.enumerated().map { i, e in
            var s = "### 후보 \(i + 1): \(e.title)\n- 시간: \(e.start) ~ \(e.end) (녹음과 겹친 시간 \(e.overlapSeconds / 60)분)\n"
            s += "- 주최자: \(e.organizer.isEmpty ? "(없음)" : e.organizer)\n"
            s += "- 참석자: \(e.attendees.isEmpty ? "(없음)" : e.attendees.joined(separator: ", "))\n"
            s += "- 위치: \(e.location.isEmpty ? "(없음)" : e.location)\n"
            s += "- 화상회의 링크: \(e.videoLink ? "있음" : "없음")\n"
            if !e.notes.isEmpty { s += "- 설명: \(e.notes)\n" }
            return s
        }.joined(separator: "\n")
    }

    /// 전사본 헤더에 한 줄로 넣는 직렬화(JSON, 줄바꿈 없음).
    static func headerLine(_ evs: [CalEvent]) -> String {
        guard !evs.isEmpty, let d = try? JSONEncoder().encode(evs), let s = String(data: d, encoding: .utf8) else { return "" }
        return "\n캘린더: " + s
    }
    static func parseHeader(_ s: String) -> [CalEvent] {
        (try? JSONDecoder().decode([CalEvent].self, from: Data(s.utf8))) ?? []
    }
}
