//! What the relay keeps on disk: which squads have a room, and the hashes of the secrets that
//! open one. No names, no rosters, no positions, and no secret itself.

use rusqlite::{params, Connection, OptionalExtension};

pub struct Store {
    db: Connection,
}

pub struct Limits {
    pub squads: usize,
    pub devices_per_squad: usize,
}

impl Store {
    /// `path` may be ":memory:".
    pub fn open(path: &str) -> rusqlite::Result<Store> {
        let db = Connection::open(path)?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA foreign_keys = ON;
             CREATE TABLE IF NOT EXISTS squads (
                 id          TEXT PRIMARY KEY,
                 leader_hash BLOB NOT NULL,
                 created     INTEGER NOT NULL,
                 seen        INTEGER NOT NULL
             );
             CREATE TABLE IF NOT EXISTS devices (
                 id         TEXT NOT NULL,
                 squad      TEXT NOT NULL REFERENCES squads(id) ON DELETE CASCADE,
                 token_hash BLOB NOT NULL UNIQUE,
                 created    INTEGER NOT NULL,
                 PRIMARY KEY (squad, id)
             );
             CREATE TABLE IF NOT EXISTS invites (
                 squad    TEXT NOT NULL REFERENCES squads(id) ON DELETE CASCADE,
                 key_hash BLOB NOT NULL,
                 expires  INTEGER NOT NULL,
                 PRIMARY KEY (squad, key_hash)
             );",
        )?;
        Ok(Store { db })
    }

    /// False if the squad already has a room, or the relay is full.
    pub fn create_squad(&self, id: &str, leader_hash: &[u8], now: i64, limits: &Limits) -> rusqlite::Result<bool> {
        let count: usize = self.db.query_row("SELECT COUNT(*) FROM squads", [], |r| r.get(0))?;
        if count >= limits.squads {
            return Ok(false);
        }
        let n = self.db.execute(
            "INSERT OR IGNORE INTO squads (id, leader_hash, created, seen) VALUES (?1, ?2, ?3, ?3)",
            params![id, leader_hash, now],
        )?;
        Ok(n == 1)
    }

    pub fn leader_hash(&self, id: &str) -> rusqlite::Result<Option<Vec<u8>>> {
        self.db
            .query_row("SELECT leader_hash FROM squads WHERE id = ?1", [id], |r| r.get(0))
            .optional()
    }

    pub fn touch(&self, id: &str, now: i64) -> rusqlite::Result<()> {
        self.db.execute("UPDATE squads SET seen = ?2 WHERE id = ?1", params![id, now])?;
        Ok(())
    }

    /// Replaces the squad's open invites.
    pub fn set_invites(&mut self, id: &str, invites: &[(Vec<u8>, i64)]) -> rusqlite::Result<()> {
        let tx = self.db.transaction()?;
        tx.execute("DELETE FROM invites WHERE squad = ?1", [id])?;
        for (hash, expires) in invites {
            tx.execute(
                "INSERT OR REPLACE INTO invites (squad, key_hash, expires) VALUES (?1, ?2, ?3)",
                params![id, hash, expires],
            )?;
        }
        tx.commit()
    }

    pub fn invite_open(&self, id: &str, key_hash: &[u8], now: i64) -> rusqlite::Result<bool> {
        let found: Option<i64> = self
            .db
            .query_row(
                "SELECT 1 FROM invites WHERE squad = ?1 AND key_hash = ?2 AND expires > ?3",
                params![id, key_hash, now],
                |r| r.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    /// False if the squad has as many devices as it may.
    pub fn add_device(&self, squad: &str, device: &str, token_hash: &[u8], now: i64, limits: &Limits) -> rusqlite::Result<bool> {
        let count: usize = self
            .db
            .query_row("SELECT COUNT(*) FROM devices WHERE squad = ?1", [squad], |r| r.get(0))?;
        if count >= limits.devices_per_squad {
            return Ok(false);
        }
        self.db.execute(
            "INSERT INTO devices (id, squad, token_hash, created) VALUES (?1, ?2, ?3, ?4)",
            params![device, squad, token_hash, now],
        )?;
        Ok(true)
    }

    /// The squad and device a token belongs to.
    pub fn device(&self, token_hash: &[u8]) -> rusqlite::Result<Option<(String, String)>> {
        self.db
            .query_row("SELECT squad, id FROM devices WHERE token_hash = ?1", [token_hash], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })
            .optional()
    }

    pub fn remove_device(&self, squad: &str, device: &str) -> rusqlite::Result<()> {
        self.db
            .execute("DELETE FROM devices WHERE squad = ?1 AND id = ?2", params![squad, device])?;
        Ok(())
    }

    pub fn remove_squad(&self, id: &str) -> rusqlite::Result<()> {
        self.db.execute("DELETE FROM squads WHERE id = ?1", [id])?;
        Ok(())
    }

    /// Drops invites that have expired and squads whose leader hasn't connected since `idle_before`.
    pub fn sweep(&self, now: i64, idle_before: i64) -> rusqlite::Result<()> {
        self.db.execute("DELETE FROM invites WHERE expires <= ?1", [now])?;
        self.db.execute("DELETE FROM squads WHERE seen < ?1", [idle_before])?;
        Ok(())
    }

    #[cfg(test)]
    pub fn dump(&self) -> String {
        self.db
            .query_row("SELECT group_concat(sql, ' ') FROM sqlite_master", [], |r| r.get::<_, String>(0))
            .unwrap_or_default()
    }
}
