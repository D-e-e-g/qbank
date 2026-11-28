/// The clock belongs to one routed transaction. Temporary triggers also see bulk updates and
/// changes made by foreign keys. Imports of whole archives run without a clock and keep their times.
enum BankWriteTime {
    static func install(on connection: SQLiteConnection) throws(StoreError) {
        try connection.run("CREATE TEMP TABLE bank_write_time (at TEXT NOT NULL)")
        for table in BankChangeTimeStep.tables {
            let columns = try connection.run("PRAGMA table_info(\(table))").compactMap { $0.text("name") }
            let changed = columns.filter { $0 != "updated_at" }.map { "OLD.\($0) IS NOT NEW.\($0)" }.joined(separator: " OR ")
            for (event, condition) in [("INSERT", "NEW.updated_at IS NULL"), ("UPDATE", "NEW.updated_at IS OLD.updated_at AND (\(changed))")] {
                try connection.run(
                    """
                    CREATE TEMP TRIGGER stamp_\(table)_\(event) AFTER \(event) ON main.\(table)
                    WHEN EXISTS (SELECT 1 FROM bank_write_time) AND \(condition)
                    BEGIN
                        UPDATE \(table) SET updated_at = (SELECT at FROM bank_write_time) WHERE rowid = NEW.rowid;
                    END
                    """)
            }
        }
    }

    /// A thrown error rolls the clock back together with the request's writes.
    static func withTime<Result>(_ time: String, in tx: StoreTransaction, _ body: () throws -> Result) throws -> Result {
        try tx.execute("INSERT INTO bank_write_time VALUES (?)", [.text(time)])
        let result = try body()
        try tx.execute("DELETE FROM bank_write_time")
        return result
    }
}
