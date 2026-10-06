import Foundation

/// Schema-9 additions copied from immutable a2c58df production sources.
/// Both the inherited schema-8 DDL and these additions are frozen.
enum AuthoritySchemaNine {
    static let cleanupStatements = [
        "CREATE TABLE IF NOT EXISTS episode_cleanup_budget(episode_id TEXT COLLATE BINARY NOT NULL PRIMARY KEY REFERENCES episodes(id),classification TEXT NOT NULL CHECK(classification IN ('prepaid-v1','legacy-administrative')),limit_rows INTEGER NOT NULL CHECK(limit_rows>=1 AND limit_rows<=100000),prepaid_rows INTEGER NOT NULL CHECK(prepaid_rows>=0 AND prepaid_rows<=limit_rows),consumed_rows INTEGER NOT NULL CHECK(consumed_rows>=0 AND consumed_rows<=prepaid_rows),pending_rows INTEGER NOT NULL CHECK(pending_rows>=0 AND pending_rows<=prepaid_rows),attempted_rows INTEGER NOT NULL CHECK(attempted_rows>=0 AND attempted_rows<=2*prepaid_rows),administrative_rows INTEGER NOT NULL CHECK(administrative_rows>=0),terminal_ticks INTEGER NOT NULL CHECK(terminal_ticks>=0),CHECK(consumed_rows+pending_rows<=prepaid_rows))",
        "CREATE TABLE IF NOT EXISTS episode_cleanup_receipts(work_id TEXT COLLATE BINARY NOT NULL PRIMARY KEY REFERENCES episode_work(id),episode_id TEXT COLLATE BINARY NOT NULL REFERENCES episode_cleanup_budget(episode_id),from_state TEXT NOT NULL CHECK(from_state IN ('prepared','dispatchArmed','submitted')),ticks INTEGER NOT NULL CHECK(ticks>0))",
        "CREATE INDEX IF NOT EXISTS episode_cleanup_pending ON episode_work(episode_id,id) WHERE state IN ('prepared','dispatchArmed','submitted')"
    ]
    static let sql = AuthoritySchemaEight.sql + "\n" + cleanupStatements.joined(separator: ";\n") + ";\nPRAGMA user_version=9;"
}
