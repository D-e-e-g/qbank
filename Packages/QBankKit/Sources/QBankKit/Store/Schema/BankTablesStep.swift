import Foundation

/// Step 1: the twelve tables of one person's bank, as `docs/on-phone-bank.md` lists them.
///
/// They mirror the server's tables: the same names, columns, nullability and references, so moving a
/// bank is a row copy. The server's `owner_id`, `user_id` and `practice_set.imported_by` are left
/// out, since one file is one person's bank. The table order puts each table after the ones it
/// refers to.
enum BankTablesStep {
    static let step = SchemaStep(number: 1, name: "bank tables", statements: tables + indexes)

    private static let tables: [String] = [
        SchemaStep.table(
            "semester",
            [
                Column.id("id", key: true),
                Column.int("number", check: "number BETWEEN 1 AND 3"),
                Column.text("name"),
                Column.date("starts_on", null: true),
                Column.date("ends_on", null: true),
                Column.time("archived_at", null: true),
                Column.time("created_at"),
                "UNIQUE (number)",
            ]),
        SchemaStep.table(
            "course",
            [
                Column.id("id", key: true),
                Column.id("semester_id", null: true, references: "semester (id)"),
                Column.text("kind", oneOf: ["course", "topic"]),
                Column.text("code"),
                Column.text("title"),
                Column.int("sort_order"),
                Column.time("archived_at", null: true),
                Column.time("created_at"),
            ] + Column.deletion + ["CHECK ((semester_id IS NOT NULL) = (kind = 'course'))"]),
        SchemaStep.table(
            "course_exam",
            [
                Column.id("id", key: true),
                Column.id("course_id", references: "course (id)"),
                Column.text("name"),
                Column.int("sort_order"),
                Column.text("link_url", null: true),
                Column.text("badge", null: true, oneOf: ["exam", "concept", "study"]),
                Column.time("created_at"),
            ] + Column.deletion),
        SchemaStep.table(
            "folder",
            [
                Column.id("id", key: true),
                Column.id("course_id", references: "course (id)"),
                Column.text("name"),
                Column.id("course_exam_id", null: true, references: "course_exam (id)", onDelete: "SET NULL"),
                Column.int("sort_order"),
                Column.time("created_at"),
            ] + Column.deletion),
        SchemaStep.table(
            "practice_set",
            [
                Column.id("id", key: true),
                Column.id("course_id", references: "course (id)"),
                Column.id("lineage_id"),
                Column.text("title"),
                Column.text("description"),
                Column.text("week_label"),
                Column.id("folder_id", null: true, references: "folder (id)"),
                Column.int("sort_order"),
                Column.time("imported_at"),
                Column.text("file_hash"),
                Column.json("stats", .object),
                Column.bool("is_current"),
                Column.time("replaced_at", null: true),
                Column.text("kind", oneOf: ["practice", "exam"]),
            ] + Column.deletion),
        SchemaStep.table(
            "question",
            [
                Column.id("id", key: true),
                Column.id("set_id", references: "practice_set (id)"),
                Column.id("lineage_id"),
                Column.text("public_id"),
                Column.int("position", check: "position >= 1"),
                Column.text("type"),
                Column.text("topic"),
                Column.text("cj", null: true),
                Column.text("client_need", null: true),
                Column.int("difficulty", null: true),
                Column.text("week_label"),
                Column.text("stem"),
                Column.text("ask"),
                Column.json("body", .object),
                Column.text("rationale"),
                Column.text("takeaway"),
                Column.json("term_keys", .array),
                Column.text("source", null: true),
                Column.text("content_hash"),
                Column.text("twin_of", null: true),
                Column.id("twin_of_lineage_id", null: true),
            ]),
        SchemaStep.table(
            "term",
            [
                Column.id("id", key: true),
                Column.id("set_id", references: "practice_set (id)"),
                Column.text("key"),
                Column.text("term"),
                Column.text("meaning"),
            ]),
        SchemaStep.table(
            "study_session",
            [
                Column.id("id", key: true),
                Column.id("course_id", references: "course (id)"),
                Column.text("mode", oneOf: ["practice", "exam", "review"]),
                Column.id("set_id", null: true, references: "practice_set (id)"),
                Column.json("question_ids", .array),
                Column.json("exam_weeks", .array, null: true),
                Column.json("exam_folder_ids", .array, null: true),
                Column.int("time_limit_seconds", null: true),
                Column.time("started_at"),
                Column.time("finished_at", null: true),
                Column.json("score", .object, null: true),
                Column.text("end_reason", null: true, oneOf: ["finished", "left", "timeout"]),
                Column.text("exam_pool", oneOf: ["all", "wrong"]),
                Column.json("exam_practice_weeks", .array, null: true),
                Column.json("seeded_question_ids", .array, null: true),
            ] + Column.deletion),
        SchemaStep.table(
            "attempt",
            [
                Column.id("id", key: true),
                Column.id("client_attempt_id"),
                Column.id("study_session_id", null: true, references: "study_session (id)"),
                Column.id("question_id", references: "question (id)"),
                Column.json("response"),
                Column.json("shuffle", null: true),
                Column.text("status", oneOf: ["correct", "partial", "incorrect"]),
                Column.int("points"),
                Column.int("max_points"),
                Column.bool("guessed"),
                Column.time("answered_at"),
                "UNIQUE (client_attempt_id)",
            ]),
        SchemaStep.table(
            "question_progress",
            [
                Column.id("question_lineage_id", key: true),
                Column.int("attempts"),
                Column.int("correct_attempts"),
                Column.text("last_status", oneOf: ["correct", "partial", "incorrect"]),
                Column.bool("last_guessed"),
                Column.time("last_answered_at"),
                Column.int("last_points"),
                Column.int("last_max_points"),
                Column.bool("in_review"),
                Column.id("last_attempt_id", references: "attempt (id)"),
            ]),
        SchemaStep.table(
            "review_clear",
            [
                Column.id("question_lineage_id", key: true),
                Column.id("last_attempt_id", references: "attempt (id)"),
                Column.time("cleared_at"),
            ]),
        SchemaStep.table(
            "study_place",
            [
                Column.id("course_id", references: "course (id)"),
                Column.time("updated_at"),
            ]),
    ]

    private static let indexes: [String] = [
        // The server's rules that SQLite cannot state as a column rule. SQLite treats nulls as
        // distinct, so a folder's two optional parts fold to a fixed value, which keeps the
        // server's "nulls not distinct" and its count of each delete apart. The server's rule is
        // deferred to the end of a transaction so two folders can swap names; SQLite checks a
        // unique index at each statement, so the engine swaps through a temporary name.
        "CREATE UNIQUE INDEX folder_name_in_list ON folder (course_id, ifnull(course_exam_id, ''), name, ifnull(deletion_id, ''))",
        // A topic's title is unique ignoring case among topics that are not deleted. SQLite's
        // lower() folds ASCII only, so the engine checks the full Unicode rule too.
        "CREATE UNIQUE INDEX course_topic_title ON course (lower(title)) WHERE kind = 'topic' AND deleted_at IS NULL",
        // At most one row: every row indexes the same constant.
        "CREATE UNIQUE INDEX study_place_one ON study_place ((1))",

        // The server's deletion marks and review list, then an index on each reference.
        "CREATE INDEX practice_set_deletion ON practice_set (deletion_id) WHERE deletion_id IS NOT NULL",
        "CREATE INDEX folder_deletion ON folder (deletion_id) WHERE deletion_id IS NOT NULL",
        "CREATE INDEX question_progress_review ON question_progress (in_review)",
        "CREATE INDEX course_semester ON course (semester_id)",
        "CREATE INDEX course_exam_course ON course_exam (course_id)",
        "CREATE INDEX folder_course_exam ON folder (course_exam_id)",
        "CREATE INDEX practice_set_course ON practice_set (course_id)",
        "CREATE INDEX practice_set_folder ON practice_set (folder_id)",
        "CREATE INDEX practice_set_lineage ON practice_set (lineage_id)",
        "CREATE INDEX question_set ON question (set_id, position)",
        "CREATE INDEX question_lineage ON question (lineage_id)",
        "CREATE INDEX term_set ON term (set_id)",
        "CREATE INDEX study_session_course ON study_session (course_id)",
        "CREATE INDEX study_session_set ON study_session (set_id)",
        "CREATE INDEX attempt_study_session ON attempt (study_session_id)",
        "CREATE INDEX attempt_question ON attempt (question_id)",
        "CREATE INDEX question_progress_attempt ON question_progress (last_attempt_id)",
        "CREATE INDEX review_clear_attempt ON review_clear (last_attempt_id)",
        "CREATE INDEX study_place_course ON study_place (course_id)",
    ]
}
