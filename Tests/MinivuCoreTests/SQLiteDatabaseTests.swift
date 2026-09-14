import Testing
import Foundation
import SQLite3
@testable import MinivuCore

@Suite struct SQLiteDatabaseTests {
    func makeTable() throws -> SQLiteDatabase {
        let db = try SQLiteDatabase.inMemory()
        try db.executeScript("""
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, score REAL, payload BLOB);
            CREATE TABLE tags (item INTEGER REFERENCES items(id), tag TEXT);
            """)
        return db
    }

    @Test func roundTripsEveryValueType() throws {
        let db = try makeTable()
        let blob = Data([0, 1, 2, 255])
        try db.execute("INSERT INTO items (name, score, payload) VALUES (?, ?, ?)",
                       [.text("Café 📷 \u{0}inside"), .real(2.5), .blob(blob)])
        try db.execute("INSERT INTO items (name, score, payload) VALUES (?, ?, ?)", [.null, .integer(7), .blob(Data())])

        let rows = try db.query("SELECT id, name, score, payload FROM items ORDER BY id")
        #expect(rows.count == 2)
        #expect(rows[0].int("id") == 1)
        #expect(rows[0].string("name") == "Café 📷 \u{0}inside")
        #expect(rows[0].double("score") == 2.5)
        #expect(rows[0].data("payload") == blob)
        #expect(rows[1]["name"] == .null)
        #expect(rows[1]["score"] == .real(7))                // REAL column affinity converts
        #expect(rows[1]["payload"] == .blob(Data()))         // empty blob, not NULL
        #expect(rows[1]["no such column"] == .null)
    }

    @Test func lastInsertRowIDAndChanges() throws {
        let db = try makeTable()
        try db.execute("INSERT INTO items (name) VALUES (?)", [.text("a")])
        try db.execute("INSERT INTO items (name) VALUES (?)", [.text("b")])
        #expect(db.lastInsertRowID == 2)
        try db.execute("UPDATE items SET score = 1")
        #expect(db.changes == 2)
    }

    @Test func transactionCommitsAndRollsBack() throws {
        let db = try makeTable()
        let id: Int64 = try db.transaction {
            try db.execute("INSERT INTO items (name) VALUES ('kept')")
            return db.lastInsertRowID
        }
        #expect(id == 1)

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try db.transaction {
                try db.execute("INSERT INTO items (name) VALUES ('discarded')")
                throw Boom()
            }
        }
        #expect(try db.query("SELECT name FROM items").map { $0.string("name") } == ["kept"])
    }

    @Test func nestedTransactionRollsBackOnlyInnerWork() throws {
        let db = try makeTable()
        struct Boom: Error {}
        try db.transaction {
            try db.execute("INSERT INTO items (name) VALUES ('outer')")
            try? db.transaction {
                try db.execute("INSERT INTO items (name) VALUES ('inner')")
                throw Boom()
            }
            try db.transaction {
                try db.execute("INSERT INTO items (name) VALUES ('inner ok')")
            }
        }
        #expect(try db.query("SELECT name FROM items ORDER BY id").map { $0.string("name") } == ["outer", "inner ok"])
    }

    @Test func userVersion() throws {
        let db = try SQLiteDatabase.inMemory()
        #expect(try db.userVersion() == 0)
        try db.setUserVersion(3)
        #expect(try db.userVersion() == 3)
    }

    @Test func errorsCarryCodeAndSQL() throws {
        let db = try makeTable()
        do {
            try db.execute("INSERT INTO nowhere VALUES (1)")
            Issue.record("expected an error")
        } catch let error as SQLiteError {
            #expect(error.code == SQLITE_ERROR)
            #expect(error.message.contains("nowhere"))
            #expect(error.sql == "INSERT INTO nowhere VALUES (1)")
        }
        #expect(throws: SQLiteError.self) { try db.execute("INSERT INTO items (name) VALUES (?)", []) }
        #expect(throws: SQLiteError.self) { try db.execute("SELECT 1; SELECT 2") }
        // Errors leave the connection usable.
        #expect(try db.query("SELECT 1 AS one").first?.int("one") == 1)
    }

    @Test func foreignKeysAreEnforced() throws {
        let db = try makeTable()
        #expect(throws: SQLiteError.self) { try db.execute("INSERT INTO tags (item, tag) VALUES (99, 'x')") }
    }

    @Test func fileDatabaseUsesWALAndCreatesFolders() throws {
        let t = try TemporaryFolder()
        let url = t.url.appendingPathComponent("nested/deeper/catalog.sqlite")
        do {
            let db = try SQLiteDatabase(url: url)
            #expect(try db.query("PRAGMA journal_mode").first?.string("journal_mode") == "wal")
            #expect(try db.query("PRAGMA synchronous").first?.int("synchronous") == 1)   // NORMAL
            try db.executeScript("CREATE TABLE t (v INTEGER)")
            try db.execute("INSERT INTO t VALUES (?)", [.integer(42)])
        }
        let reopened = try SQLiteDatabase(url: url)
        #expect(try reopened.query("SELECT v FROM t").first?.int("v") == 42)
    }

    @Test func concurrentWritersAndReaders() throws {
        let db = try makeTable()
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for i in 0..<100 {
                try? db.transaction {
                    try db.execute("INSERT INTO items (name, score) VALUES (?, ?)", [.text("w\(worker)"), .integer(Int64(i))])
                    _ = try db.query("SELECT COUNT(*) AS n FROM items")
                }
            }
        }
        #expect(try db.query("SELECT COUNT(*) AS n FROM items").first?.int("n") == 800)
    }
}
