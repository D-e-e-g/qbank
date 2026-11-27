/// Existing rows keep their original values. Their time stays unknown until the engine changes them.
enum BankChangeTimeStep {
    static let tables = ["semester", "course", "course_exam", "folder", "practice_set", "study_session"]

    static let step = SchemaStep(
        number: 2, name: "bank row change times and archive stamp",
        statements: tables.map { "ALTER TABLE \($0) ADD COLUMN \(Column.time("updated_at", null: true))" } + [
            // A downloaded bank keeps its server stamp even when all twelve lists are empty.
            "CREATE TABLE bank_archive (singleton INTEGER PRIMARY KEY CHECK (singleton = 1), stamp TEXT NOT NULL) STRICT"
        ])
}
