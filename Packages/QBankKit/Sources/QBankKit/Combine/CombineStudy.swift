import Foundation

extension CombinePlan {
    mutating func combineStudy() throws {
        for (id, source) in phone["studySessions"].sorted(by: { $0.key < $1.key }) {
            var row = source
            row["courseId"] = remap(source, "courseId", to: "courses")
            row["setId"] = remap(source, "setId", to: "practiceSets")
            for field in ["questionIds", "seededQuestionIds", "examFolderIds", "score"] {
                if let json = source.text(field) { row[field] = try .text(remapJSON(json, field: field)) }
            }
            if let held = server["studySessions"][id] {
                join("studySessions", id, to: id, rule: "ID-13")
                let finish = ["finishedAt", "endReason", "score"]
                var result = settle(held, row, fields: finish + ["examFolderIds", "deletedAt", "deletionId"])
                if held.text("finishedAt") == nil && row.text("finishedAt") != nil { result.copy(finish, from: row) }
                if held.text("finishedAt") != nil && row.text("finishedAt") == nil { result.copy(finish, from: held) }
                row = result
            }
            rows["studySessions", default: [:]][id] = row
        }

        let clients = Dictionary(uniqueKeysWithValues: server["attempts"].map { ($0.value.text("clientAttemptId") ?? "", $0.key) })
        var pairedAnswers: Set<String> = []
        for (id, source) in phone["attempts"].sorted(by: { $0.key < $1.key }) {
            let peer = clients[source.text("clientAttemptId") ?? ""]
            if server["attempts"][id] != nil, let peer, id != peer {
                throw BankArchiveError.invalid("an answer's two ids identify different server answers.")
            }
            if let key = server["attempts"][id] == nil ? peer : id {
                guard pairedAnswers.insert(key).inserted else { throw BankArchiveError.invalid("two phone answers identify the same server answer.") }
                join("attempts", id, to: key, rule: "ID-14")
            } else {
                var row = source
                row["questionId"] = remap(row, "questionId", to: "questions")
                rows["attempts", default: [:]][id] = row
            }
        }
        for (table, rule) in [("questionProgress", "ID-15"), ("reviewClears", "ID-16")] {
            for (lineage, source) in phone[table].sorted(by: { $0.key < $1.key }) {
                let key = questionLineages[lineage] ?? lineage
                var row = source
                row["questionLineageId"] = .text(key)
                row["lastAttemptId"] = remap(row, "lastAttemptId", to: "attempts")
                if let held = server[table][key] {
                    join(table, lineage, to: key, rule: rule)
                    if table == "questionProgress" || (held.text("clearedAt") ?? "") >= (row.text("clearedAt") ?? "") { continue }
                }
                rows[table, default: [:]][key] = row
            }
        }
        if var place = phone["studyPlace"]["place"] {
            if let held = server["studyPlace"]["place"] {
                join("studyPlace", "place", to: "place", rule: "ID-17")
                if held.changed >= place.changed { return }
            }
            place["courseId"] = remap(place, "courseId", to: "courses")
            rows["studyPlace"] = ["place": place]
        }
    }

    /// Rewrite only reference slots. In particular a response, label, or unknown score field
    /// can contain an id as text and must survive byte for byte.
    private func remapJSON(_ text: String, field: String) throws -> String {
        let doc = try ArchiveScanner.scan(Data(text.utf8))
        var replacements: [(Range<Int>, String)] = []
        func replace(_ node: ArchiveNode?, _ table: String) {
            guard let node, let id = node.string else { return }
            let mapped = target(table, id)
            if mapped != id { replacements.append((node.range, mapped)) }
        }
        if field == "score" {
            let fields = doc.root.fields
            for item in fields?["items"]?.items ?? [] { replace(item.fields?["questionId"], "questions") }
            for item in fields?["byFolder"]?.items ?? [] { replace(item.fields?["folderId"], "folders") }
        } else {
            for node in doc.root.items ?? [] { replace(node, field == "examFolderIds" ? "folders" : "questions") }
        }
        if replacements.isEmpty { return text }
        var bytes: [UInt8] = []
        var start = 0
        for (range, id) in replacements.sorted(by: { $0.0.lowerBound < $1.0.lowerBound }) {
            bytes += doc.bytes[start..<range.lowerBound]
            bytes += BankArchiveWriter.quote(id).utf8
            start = range.upperBound
        }
        bytes += doc.bytes[start...]
        return String(decoding: bytes, as: UTF8.self)
    }

    func closeCompetingExams(in tx: StoreTransaction) throws {
        let exams = try ExamStore.open(tx).filter { exam in
            // Archive durations are Int64. Reject an unrepresentable deadline before calling
            // the exam clock, which works in integer milliseconds.
            let (duration, tooLong) = (exam.limitSeconds ?? 0).multipliedReportingOverflow(by: 1000)
            let (end, tooLate) = (ExamClock.milliseconds(exam.startedAt) ?? 0).addingReportingOverflow(duration)
            guard !tooLong, !tooLate, !end.addingReportingOverflow(ExamClock.graceMilliseconds).overflow else {
                throw BankArchiveError.invalid("an exam deadline cannot be represented.")
            }
            return ExamClock.isOpen(exam.status(now))
        }
        for exam in exams.dropFirst() {
            let ending = try ExamStore.ending(of: exam, reason: "left", tx, now)
            let row = rows["studySessions"]?[exam.id]
            let time = QBankJSON.formatDate(now)
            let updated = try server["studySessions"][exam.id].map { try changeTime(after: $0.changed, proposed: row?.changed ?? time) } ?? max(time, row?.changed ?? "")
            // WIN-13 includes the grace period. Use the engine's score and end time, and record
            // that this exam ended because a later one was left running.
            try tx.execute(
                "UPDATE study_session SET finished_at = ?, score = ?, end_reason = 'left', updated_at = ? WHERE id = ?",
                [.text(ending.finishedAt), .text(Stored.json(ending.score)), .text(updated), .text(exam.id)])
        }
    }
}
