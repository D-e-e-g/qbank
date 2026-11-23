import Foundation

/// How many questions an exam takes from each folder it is over, and its time: the server's `planExam`.
///
/// Up to 40 questions in 60 minutes. When the folders hold fewer than 40, the exam is all of them at
/// 1.5 minutes each. A larger pool is split in proportion to each folder's size by largest remainder,
/// so folders holding 22, 27 and 37 give 10 + 13 + 17. A folder with questions always gives at
/// least one, so every ticked folder stays represented.
public enum ExamPlanner {
    /// The rules every exam keeps, as Exam setup sends them.
    public static let rules = ExamRules(maxQuestions: 40, fullTimeSeconds: 60 * 60, secondsPerQuestion: 90)

    /// A ticked folder and how many questions it holds in the pool.
    public struct Pool: Sendable, Equatable {
        public let label: String
        public let questionCount: Int

        public init(label: String, questionCount: Int) {
            self.label = label
            self.questionCount = questionCount
        }
    }

    /// What the exam takes from one ticked folder.
    public struct Draw: Sendable, Equatable {
        public let label: String
        public let questionCount: Int
        /// How many of the folder's questions the exam takes.
        public let drawn: Int
    }

    public struct Plan: Sendable, Equatable {
        public let questionCount: Int
        public let timeLimitSeconds: Int
        /// One per ticked folder, in the order given.
        public let draws: [Draw]
    }

    /// The plan for these folders under `rules`, which are the server's unless a test plays another server.
    public static func plan(_ pools: [Pool], rules: ExamRules = ExamPlanner.rules) -> Plan {
        let sizes = pools.map { max(0, $0.questionCount) }
        let pool = sizes.reduce(0, +)
        let most = rules.maxQuestions
        guard pool > most else {
            return Plan(
                questionCount: pool, timeLimitSeconds: pool * rules.secondsPerQuestion,
                draws: zip(pools, sizes).map { Draw(label: $0.label, questionCount: $1, drawn: $1) })
        }

        let quotas = sizes.map { Double($0 * most) / Double(pool) }
        var drawn = quotas.map { Int($0.rounded(.down)) }
        var left = most - drawn.reduce(0, +)
        let remainder = { (index: Int) in quotas[index] - quotas[index].rounded(.down) }
        let byRemainder = quotas.indices.sorted { a, b in
            if remainder(a) != remainder(b) { return remainder(a) > remainder(b) }
            if sizes[a] != sizes[b] { return sizes[a] > sizes[b] }
            return a < b
        }
        for index in byRemainder where left > 0 {
            drawn[index] += 1
            left -= 1
        }

        // A small folder next to large ones can round to 0. It borrows one from the folder that is
        // furthest over its share, so the total stays 40.
        let surplus = { (index: Int) in Double(drawn[index]) - quotas[index] }
        for index in drawn.indices where sizes[index] != 0 && drawn[index] == 0 {
            var lender: Int?
            for other in drawn.indices where drawn[other] > 1 {
                if let current = lender, surplus(other) <= surplus(current) { continue }
                lender = other
            }
            guard let lender else { break }
            drawn[lender] -= 1
            drawn[index] = 1
        }
        return Plan(
            questionCount: most, timeLimitSeconds: rules.fullTimeSeconds,
            draws: pools.indices.map { Draw(label: pools[$0].label, questionCount: sizes[$0], drawn: drawn[$0]) })
    }
}

/// Where a timed exam stands. Only its end is stored (`finished_at`); the rest is told from the
/// clock, here and nowhere else, so every reader agrees on the moment an exam stops being open.
enum ExamClock {
    /// How long after an exam's time runs out an answer sent before the end is still taken.
    static let graceMilliseconds = 30_000

    /// - running: before its end time.
    /// - grace: its time has run out, and an answer sent before the end is still taken. Nothing ends it but the person's own app asking to.
    /// - expired: time up, past the grace, and its end is not recorded yet. It takes nothing more, so what it scores is settled, and every reader is shown it as ended.
    /// - ended: its end is recorded.
    enum Status: String {
        case running, grace, expired, ended

        /// What a reader is told: an exam whose time is up reads as ended, whether or not its end is recorded yet.
        var read: String { self == .expired ? "ended" : rawValue }
    }

    static func milliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }

    static func milliseconds(_ text: String) -> Int? { QBankJSON.parseDate(text).map(milliseconds) }

    /// When the exam's time runs out, in milliseconds since 1970.
    static func endsAt(startedAt: String, limitSeconds: Int?) -> Int { (milliseconds(startedAt) ?? 0) + (limitSeconds ?? 0) * 1000 }

    static func text(milliseconds: Int) -> String { QBankJSON.formatDate(Date(timeIntervalSince1970: Double(milliseconds) / 1000)) }

    static func status(startedAt: String, limitSeconds: Int?, finishedAt: String?, now: Date) -> Status {
        if finishedAt != nil { return .ended }
        let end = endsAt(startedAt: startedAt, limitSeconds: limitSeconds)
        let at = milliseconds(now)
        if at < end { return .running }
        return at <= end + graceMilliseconds ? .grace : .expired
    }

    /// Still open, running or in its grace: it takes an answer, and what would end it waits.
    static func isOpen(_ status: Status) -> Bool { status == .running || status == .grace }
}
