//! Encrypted notes vault: one SQLCipher database, one `notes` table.
//! Adapted from desktop `confidential/vault.rs` and `database/manager.rs`
//! (key pragmas, plaintext-header rejection, wrong-key detection).
//!
//! The vault is keyed with a random 32-byte raw key (`PRAGMA key = "x'..'"`),
//! so SQLCipher skips its passphrase KDF. The key is generated here
//! (`generate_vault_key`); the app wraps it with a Secure Enclave key.

use crate::CoreError;
use rusqlite::{params, Connection, ErrorCode, OpenFlags};

/// Private cloud activation stored in the vault (`vault/cloud.rs`).
mod cloud;
pub use cloud::CreditStatus;
use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroize::Zeroizing;

/// Stable message for a key SQLCipher rejects (Swift matches on it).
pub const WRONG_KEY: &str = "wrong-key";

/// Raw SQLCipher key length (AES-256).
pub const VAULT_KEY_LEN: usize = 32;

/// 32 bytes from the OS CSPRNG (`getentropy`), for `Vault.create`.
#[uniffi::export]
pub fn generate_vault_key() -> Result<Vec<u8>, CoreError> {
    let mut key = vec![0u8; VAULT_KEY_LEN];
    // SAFETY: `key` is a valid writable buffer of VAULT_KEY_LEN (<= 256) bytes.
    let rc = unsafe { libc::getentropy(key.as_mut_ptr().cast(), key.len()) };
    if rc != 0 {
        key.iter_mut().for_each(|b| *b = 0);
        return Err(vault_err("Could not generate a notebook key"));
    }
    Ok(key)
}

#[derive(Debug, Clone, uniffi::Record)]
pub struct NoteSummary {
    pub id: String,
    pub title: String,
    pub created_at_ms: i64,
}

#[derive(uniffi::Object)]
pub struct Vault {
    conn: Mutex<Option<Connection>>,
}

fn vault_err(msg: impl Into<String>) -> CoreError {
    CoreError::Vault { msg: msg.into() }
}

/// SQLCipher reports a key that does not decrypt page 1 as SQLITE_NOTADB.
fn is_wrong_key(error: &rusqlite::Error) -> bool {
    matches!(error, rusqlite::Error::SqliteFailure(e, _) if e.code == ErrorCode::NotADatabase)
}

fn exists_nonempty(path: &Path) -> bool {
    // An interrupted first open can leave an empty, unkeyed file.
    path.metadata().map_or(false, |m| m.len() > 0)
}

fn open_keyed(path: &Path, key: &[u8], create: bool) -> Result<Connection, CoreError> {
    if key.len() != VAULT_KEY_LEN {
        return Err(vault_err("Invalid notebook key length"));
    }
    // Reject recognizable plaintext before SQLite can open it.
    if let Ok(mut file) = std::fs::File::open(path) {
        use std::io::Read;
        let mut header = [0u8; 16];
        if file.read_exact(&mut header).is_ok() && &header == b"SQLite format 3\0" {
            return Err(vault_err("Plaintext databases cannot be opened as a notebook"));
        }
    }
    let mut flags = OpenFlags::SQLITE_OPEN_READ_WRITE | OpenFlags::SQLITE_OPEN_NO_MUTEX;
    if create {
        flags |= OpenFlags::SQLITE_OPEN_CREATE;
    }
    let conn = Connection::open_with_flags(path, flags).map_err(|_| vault_err("Could not open the notebook file"))?;

    // The key must be the first statement on the connection. Raw-key form
    // (`x'<64 hex>'`) skips PBKDF2. The SQL string is wiped on drop.
    let mut sql = Zeroizing::new(String::with_capacity(16 + 2 * VAULT_KEY_LEN));
    sql.push_str("PRAGMA key = \"x'");
    for b in key {
        const HEX: &[u8; 16] = b"0123456789abcdef";
        sql.push(HEX[(b >> 4) as usize] as char);
        sql.push(HEX[(b & 0xf) as usize] as char);
    }
    sql.push_str("'\";");
    conn.execute_batch(&sql).map_err(|_| vault_err("Could not key the notebook"))?;
    drop(sql);

    let version: Option<String> = conn
        .query_row("PRAGMA cipher_version", [], |r| r.get(0))
        .ok();
    if version.map_or(true, |v| v.is_empty()) {
        return Err(vault_err("Encrypted SQLite support is unavailable"));
    }
    // Force key validation now (SQLCipher defers it to the first page read).
    conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| r.get::<_, i64>(0))
        .map_err(|e| if is_wrong_key(&e) { vault_err(WRONG_KEY) } else { vault_err("Could not read the notebook. It may be damaged.") })?;

    let setup = || -> rusqlite::Result<()> {
        conn.pragma_update(None, "cipher_memory_security", "ON")?;
        conn.pragma_update(None, "temp_store", "MEMORY")?;
        conn.pragma_update(None, "secure_delete", "ON")?;
        conn.query_row("PRAGMA journal_mode = WAL", [], |_| Ok(()))?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS notes (
                id TEXT PRIMARY KEY NOT NULL,
                title TEXT NOT NULL,
                markdown TEXT NOT NULL,
                created_at_ms INTEGER NOT NULL
            );",
        )
    };
    setup().map_err(|_| vault_err("Could not prepare the notebook"))?;
    Ok(conn)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

#[uniffi::export]
impl Vault {
    /// Create a new vault. Fails if a non-empty file already exists at `path`.
    #[uniffi::constructor]
    pub fn create(path: String, key: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let key = Zeroizing::new(key);
        let path = Path::new(&path);
        if exists_nonempty(path) {
            return Err(vault_err("A notebook already exists at this path"));
        }
        let conn = open_keyed(path, &key, true)?;
        Ok(Arc::new(Self { conn: Mutex::new(Some(conn)) }))
    }

    /// Open an existing vault. A wrong key yields `Vault("wrong-key")`.
    #[uniffi::constructor]
    pub fn open(path: String, key: Vec<u8>) -> Result<Arc<Self>, CoreError> {
        let key = Zeroizing::new(key);
        let path = Path::new(&path);
        if !exists_nonempty(path) {
            return Err(vault_err("No notebook exists at this path"));
        }
        let conn = open_keyed(path, &key, false)?;
        Ok(Arc::new(Self { conn: Mutex::new(Some(conn)) }))
    }

    pub fn save_note(&self, title: String, markdown: String) -> Result<String, CoreError> {
        let title = Zeroizing::new(title);
        let markdown = Zeroizing::new(markdown);
        self.with_conn(|conn| {
            let id: String = conn.query_row("SELECT lower(hex(randomblob(16)))", [], |r| r.get(0))?;
            conn.execute(
                "INSERT INTO notes (id, title, markdown, created_at_ms) VALUES (?1, ?2, ?3, ?4)",
                params![id, title.as_str(), markdown.as_str(), now_ms()],
            )?;
            Ok(id)
        })
    }

    pub fn list_notes(&self) -> Result<Vec<NoteSummary>, CoreError> {
        self.with_conn(|conn| {
            let mut stmt =
                conn.prepare("SELECT id, title, created_at_ms FROM notes ORDER BY created_at_ms DESC, rowid DESC")?;
            let rows = stmt.query_map([], |r| {
                Ok(NoteSummary { id: r.get(0)?, title: r.get(1)?, created_at_ms: r.get(2)? })
            })?;
            rows.collect()
        })
    }

    pub fn read_note(&self, id: String) -> Result<String, CoreError> {
        self.with_conn(|conn| {
            conn.query_row("SELECT markdown FROM notes WHERE id = ?1", [id], |r| r.get(0))
        })
    }

    /// Checkpoint the WAL into the encrypted database and close. Idempotent.
    pub fn close(&self) {
        let mut guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(conn) = guard.take() {
            let _ = conn.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
            let _ = conn.close();
        }
    }
}

impl Vault {
    fn with_conn<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, CoreError> {
        let guard = self.conn.lock().unwrap_or_else(|p| p.into_inner());
        let conn = guard.as_ref().ok_or_else(|| CoreError::InvalidState { msg: "vault is closed".into() })?;
        f(conn).map_err(|e| match e {
            rusqlite::Error::QueryReturnedNoRows => vault_err("note not found"),
            _ => vault_err("notebook operation failed"),
        })
    }
}

impl Drop for Vault {
    fn drop(&mut self) {
        self.close();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const CANARY: &str = "CANARY-7f3a9c-plaintext-must-not-hit-disk";

    fn all_bytes(dir: &Path) -> Vec<(String, Vec<u8>)> {
        std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().path())
            .filter(|p| p.is_file())
            .map(|p| (p.file_name().unwrap().to_string_lossy().into_owned(), std::fs::read(&p).unwrap()))
            .collect()
    }

    fn contains(hay: &[u8], needle: &[u8]) -> bool {
        hay.windows(needle.len()).any(|w| w == needle)
    }

    #[test]
    fn vault_canary_never_reaches_disk_and_keys_are_enforced() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("vault.sqlite");
        let p = path.to_string_lossy().into_owned();
        let key = generate_vault_key().unwrap();
        assert_eq!(key.len(), VAULT_KEY_LEN);
        assert_ne!(key, generate_vault_key().unwrap(), "keys must be random");
        assert!(key.iter().any(|&b| b != 0));

        assert!(matches!(Vault::create(p.clone(), Vec::new()), Err(CoreError::Vault { .. })));
        assert!(matches!(Vault::create(p.clone(), vec![7; 31]), Err(CoreError::Vault { .. })));
        let vault = Vault::create(p.clone(), key.clone()).unwrap();
        let id = vault
            .save_note(format!("Title {CANARY}"), format!("# Notes\n\n{CANARY}\n"))
            .unwrap();
        assert_eq!(vault.list_notes().unwrap().len(), 1);

        // While open (WAL and SHM present) nothing on disk may contain the canary.
        let files = all_bytes(dir.path());
        assert!(files.iter().any(|(n, _)| n.ends_with("-wal")), "expected a WAL file: {:?}", files.iter().map(|f| &f.0).collect::<Vec<_>>());
        for (name, bytes) in &files {
            assert!(!contains(bytes, CANARY.as_bytes()), "canary in {name}");
            assert!(!contains(bytes, b"SQLite format 3"), "plaintext header in {name}");
            assert!(!contains(bytes, b"CREATE TABLE"), "plaintext schema in {name}");
        }
        assert!(Vault::create(p.clone(), key.clone()).is_err(), "create must not clobber");
        vault.close();
        assert!(matches!(vault.list_notes(), Err(CoreError::InvalidState { .. })));
        for (name, bytes) in all_bytes(dir.path()) {
            assert!(!contains(&bytes, CANARY.as_bytes()), "canary in {name} after close");
        }

        let mut wrong = key.clone();
        wrong[0] ^= 1;
        for bad in [wrong, generate_vault_key().unwrap()] {
            match Vault::open(p.clone(), bad) {
                Err(CoreError::Vault { msg }) => assert_eq!(msg, WRONG_KEY),
                Err(other) => panic!("unexpected error {other:?}"),
                Ok(_) => panic!("wrong key accepted"),
            }
        }
        assert!(matches!(Vault::open(p.clone(), key[..16].to_vec()), Err(CoreError::Vault { .. })));

        let reopened = Vault::open(p.clone(), key.clone()).unwrap();
        let notes = reopened.list_notes().unwrap();
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].id, id);
        assert_eq!(notes[0].title, format!("Title {CANARY}"));
        assert!(notes[0].created_at_ms > 0);
        assert!(reopened.read_note(id).unwrap().contains(CANARY));
        assert!(matches!(reopened.read_note("missing".into()), Err(CoreError::Vault { .. })));
        reopened.close();

        assert!(Vault::open(dir.path().join("nope").to_string_lossy().into_owned(), key).is_err());
    }

    #[test]
    fn plaintext_database_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("plain.sqlite");
        std::fs::write(&path, b"SQLite format 3\0rest-of-a-plaintext-db").unwrap();
        let err = Vault::open(path.to_string_lossy().into_owned(), generate_vault_key().unwrap());
        assert!(matches!(err, Err(CoreError::Vault { .. })));
    }
}
