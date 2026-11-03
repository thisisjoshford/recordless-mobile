//! Activation codes: Recordless's credit service (`services/trial-keys`) hands
//! over the NEAR AI key made for a code, with that code's credit as its spend
//! limit. Paying raises the same key's limit. Redeeming the code again, after a
//! reinstall for example, returns the same key.
//!
//! The service never receives meeting content: notes still go straight to the
//! verified enclave with the key it returns. Redeeming sends it the code;
//! checking the credit sends it the code's account id and key. Nothing is sent
//! until the user enters a code, and the credit is checked only after NEAR AI
//! has turned the key away for want of it, when the status is asked for.
//!
//! The key is stored in the vault but never returned to Swift. A determined
//! user can still dig it out of the app, which is why each one is capped and
//! can be revoked on its own.
//!
//! Undocumented: a NEAR AI key of the user's own can be entered in place of a
//! code. It is saved as is, with `OWN_KEY` for an account id, and never sent to
//! the credit service.
//!
//! Either way, the key is saved only once NEAR AI has accepted it.
//!
//! Ported from desktop `summary/nearai/activation.rs`; the desktop settings
//! row is the vault's `private_cloud` table here (see [`CloudDb`]).
use std::time::Duration;

use chrono::{DateTime, SecondsFormat, Utc};
use rusqlite::{params, Connection, OptionalExtension};
use serde_json::{json, Value};
use zeroize::Zeroizing;

/// Set at build time; a build without it has no private cloud credit to offer.
const SERVICE_URL: Option<&str> = option_env!("RECORDLESS_TRIAL_URL");
const TIMEOUT: Duration = Duration::from_secs(20);
const MAX_REPLY_BYTES: usize = 64 * 1024;
const UNREACHABLE: &str = "Could not reach Recordless. Check your connection and try again.";
const NEAR_AI_UNREACHABLE: &str = "Could not reach NEAR AI to check the key. Check your connection and try again.";
/// Private cloud notes were asked for before any code was redeemed.
pub const NO_ACTIVATION: &str = "Enter an activation code to use the private cloud.";
/// Shown in place of the rejected-key error while generating on code credit.
pub const CREDIT_USED_UP: &str = "Your private cloud credit has run out, or your activation code has expired.";

/// Where the activation lives: the vault (an encrypted SQLCipher database).
pub(crate) trait CloudDb {
    fn with_db<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String>;
}

const SCHEMA: &str = "CREATE TABLE IF NOT EXISTS private_cloud (
    id INTEGER PRIMARY KEY NOT NULL CHECK (id = 1),
    api_key TEXT NOT NULL,
    account_id TEXT NOT NULL,
    credit_used_up_at TEXT,
    credit_baseline_nano INTEGER
);";

fn ensure(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA)
}

mod db {
    use super::*;

    pub fn get_activation(conn: &Connection) -> rusqlite::Result<Option<(Zeroizing<String>, String)>> {
        ensure(conn)?;
        conn.query_row("SELECT api_key, account_id FROM private_cloud WHERE id = 1", [], |r| {
            Ok((Zeroizing::new(r.get::<_, String>(0)?), r.get::<_, String>(1)?))
        })
        .optional()
    }

    /// A new key starts with no run-out recorded.
    pub fn save_activation(conn: &Connection, key: &str, account_id: &str) -> rusqlite::Result<()> {
        ensure(conn)?;
        conn.execute(
            "INSERT INTO private_cloud (id, api_key, account_id) VALUES (1, ?1, ?2)
             ON CONFLICT(id) DO UPDATE SET api_key = ?1, account_id = ?2,
                 credit_used_up_at = NULL, credit_baseline_nano = NULL",
            params![key, account_id],
        )?;
        Ok(())
    }

    /// When NEAR AI last turned the key away for want of credit (RFC 3339, as
    /// stored), and the key's spend limit at the first check since.
    pub fn get_run_out(conn: &Connection) -> rusqlite::Result<Option<(String, Option<i64>)>> {
        ensure(conn)?;
        let row: Option<(Option<String>, Option<i64>)> = conn
            .query_row(
                "SELECT credit_used_up_at, credit_baseline_nano FROM private_cloud WHERE id = 1",
                [],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        Ok(row.and_then(|(at, baseline)| Some((at?, baseline))))
    }

    /// A new run-out starts without a baseline: the limit may have changed.
    pub fn record_run_out(conn: &Connection, at: &str) -> rusqlite::Result<()> {
        ensure(conn)?;
        conn.execute(
            "UPDATE private_cloud SET credit_used_up_at = ?1, credit_baseline_nano = NULL WHERE id = 1",
            [at],
        )?;
        Ok(())
    }

    /// Saved once per run-out, and only for the run-out `at` names.
    pub fn set_baseline(conn: &Connection, at: &str, nano: i64) -> rusqlite::Result<()> {
        ensure(conn)?;
        conn.execute(
            "UPDATE private_cloud SET credit_baseline_nano = ?2
             WHERE id = 1 AND credit_used_up_at = ?1 AND credit_baseline_nano IS NULL",
            params![at, nano],
        )?;
        Ok(())
    }

    /// Clears the run-out `at` names, so one recorded since is kept.
    pub fn clear_run_out(conn: &Connection, at: &str) -> rusqlite::Result<()> {
        ensure(conn)?;
        conn.execute(
            "UPDATE private_cloud SET credit_used_up_at = NULL, credit_baseline_nano = NULL
             WHERE id = 1 AND credit_used_up_at = ?1",
            [at],
        )?;
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ActivationStatus {
    /// A code (or own key) has been redeemed, with or without credit left.
    pub active: bool,
    /// This build can redeem codes.
    pub available: bool,
    /// The saved key is the user's own, not a code's.
    pub own_key: bool,
    /// NEAR AI turned the code's key away for want of credit, and since then no
    /// new code, raised credit, or private cloud run started afterwards has worked.
    pub credit_used_up: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CreditBalance {
    /// A payment hasn't been added to the key's limit yet.
    pub payment_pending: bool,
    /// When the key stops working (RFC 3339), if it ever does.
    pub expires_at: Option<String>,
    /// The code was turned off and its key revoked.
    pub disabled: bool,
    pub upgrade_url: Option<String>,
    /// The run-out is still recorded; false once a raised limit has cleared it.
    pub credit_used_up: bool,
}

fn service_url() -> Option<&'static str> {
    SERVICE_URL
        .map(|url| url.trim().trim_end_matches('/'))
        .filter(|url| url.starts_with("https://"))
}

/// Stored as the account id of a key the user entered themselves.
const OWN_KEY: &str = "own-key";

/// A NEAR AI key as Recordless's workspace issues them.
fn well_formed_key(key: &str) -> bool {
    key.starts_with("sk-")
        && (10..=256).contains(&key.len())
        && key.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn well_formed_account_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

fn stored(db: &impl CloudDb) -> Result<Option<(Zeroizing<String>, String)>, String> {
    db.with_db(db::get_activation)
        .map_err(|_| "Could not read the private cloud credit".to_string())
}

/// The key issued for the redeemed code, if any. Never leaves the core.
pub(crate) fn key(db: &impl CloudDb) -> Result<Option<Zeroizing<String>>, String> {
    Ok(stored(db)?.map(|(key, _)| key))
}

/// A failed private cloud run's error as the user sees it: NEAR AI rejecting
/// the code's key means its credit is gone.
pub fn run_error(error: String) -> String {
    if error.contains(super::KEY_REJECTED) {
        CREDIT_USED_UP.to_string()
    } else {
        error
    }
}

/// Remember that the credit ran out, and when, so the status checks with
/// Recordless only then. Losing this only costs the status's accuracy, never a run.
pub(crate) fn remember_credit_used_up(db: &impl CloudDb) {
    let now = Utc::now().to_rfc3339_opts(SecondsFormat::Nanos, true);
    if let Err(error) = db.with_db(|conn| db::record_run_out(conn, &now)) {
        log::warn!("Could not record that the private cloud credit is used up: {error}");
    }
}

/// A run that started before the credit ran out may have been sent before it
/// did, so only a later one's success says the key works again.
fn run_clears_run_out(run_started: DateTime<Utc>, used_up_at: &str) -> bool {
    DateTime::parse_from_rfc3339(used_up_at).map_or(true, |at| run_started > at)
}

/// A private cloud run that started at `run_started` succeeded.
pub(crate) fn remember_credit_works(db: &impl CloudDb, run_started: DateTime<Utc>) {
    let cleared = db.with_db(|conn| match db::get_run_out(conn)? {
        Some((at, _)) if run_clears_run_out(run_started, &at) => db::clear_run_out(conn, &at),
        _ => Ok(()),
    });
    if let Err(error) = cleared {
        log::warn!("Could not clear the private cloud credit run-out: {error}");
    }
}

/// Whether the recorded run-out still stands, given the key's spend limit now.
/// The first check after a run-out saves that limit; a higher one later means
/// a payment was applied.
fn settle_run_out(db: &impl CloudDb, granted_nano: Option<i64>) -> Result<bool, String> {
    db.with_db(|conn| {
        let Some((at, baseline)) = db::get_run_out(conn)? else {
            return Ok(false);
        };
        match (baseline, granted_nano) {
            (None, Some(granted)) => db::set_baseline(conn, &at, granted)?,
            (Some(baseline), Some(granted)) if granted > baseline => {
                db::clear_run_out(conn, &at)?;
                return Ok(false);
            }
            _ => {}
        }
        Ok(true)
    })
}

/// POST to the credit service and return its JSON reply, or its error message.
async fn post(path: &str, body: Value, bearer: Option<&str>) -> Result<Value, String> {
    let base = service_url().ok_or("Private cloud credit isn't available in this build.")?;
    let client = reqwest::Client::builder().timeout(TIMEOUT).build().map_err(|_| UNREACHABLE)?;
    let mut request = client.post(format!("{base}{path}")).json(&body);
    if let Some(key) = bearer {
        request = request.bearer_auth(key);
    }
    let response = request.send().await.map_err(|_| UNREACHABLE)?;
    let status = response.status();
    let bytes = super::remote::body_within(response, MAX_REPLY_BYTES)
        .await
        .map_err(|_| UNREACHABLE.to_string())?;
    let value: Value = serde_json::from_slice(&bytes).map_err(|_| UNREACHABLE)?;
    if !status.is_success() {
        let message = value["error"].as_str().filter(|m| m.len() <= 200).unwrap_or(UNREACHABLE);
        return Err(message.to_string());
    }
    Ok(value)
}

pub(crate) fn status(db: &impl CloudDb) -> Result<ActivationStatus, String> {
    let credit_used_up = db
        .with_db(db::get_run_out)
        .map(|run_out| run_out.is_some())
        .unwrap_or_else(|error| {
            log::warn!("Could not read whether the private cloud credit is used up: {error}");
            false
        });
    let stored = stored(db)?;
    Ok(ActivationStatus {
        active: stored.is_some(),
        available: service_url().is_some(),
        own_key: stored.as_ref().is_some_and(|(_, id)| id == OWN_KEY),
        credit_used_up,
    })
}

/// Ask NEAR AI whether it takes the key, turning a refusal into `rejected`.
async fn check_key(key: &str, rejected: &str) -> Result<(), String> {
    match super::key_accepted(key).await {
        Ok(true) => Ok(()),
        Ok(false) => Err(rejected.into()),
        Err(error) => {
            log::warn!("Could not check a NEAR AI key: {error}");
            Err(NEAR_AI_UNREACHABLE.into())
        }
    }
}

/// What redeeming needs from the network, done before the vault is touched.
pub(crate) enum Redeemed {
    Code { key: Zeroizing<String>, account_id: String },
    OwnKey { key: Zeroizing<String> },
}

/// Redeem an activation code (or check an own key) with the network. Nothing
/// is stored; [`save_redeemed`] does that once this has succeeded.
pub(crate) async fn redeem(code: &str) -> Result<Redeemed, String> {
    let code = code.trim();
    if code.starts_with("sk-") {
        if !well_formed_key(code) {
            return Err("That code isn't valid.".into());
        }
        check_key(code, "NEAR AI didn't accept that key.").await?;
        return Ok(Redeemed::OwnKey { key: Zeroizing::new(code.to_string()) });
    }
    if code.is_empty() || code.len() > 64 {
        return Err("That code isn't valid.".into());
    }
    let reply = post("/v1/redeem", json!({ "code": code }), None).await?;
    let account_id = reply["accountId"].as_str().filter(|id| well_formed_account_id(id));
    let key = reply["apiKey"].as_str().map(|k| Zeroizing::new(k.to_string()));
    let (Some(account_id), Some(key)) = (account_id, key) else {
        return Err(UNREACHABLE.into());
    };
    if !well_formed_key(&key) {
        return Err(UNREACHABLE.into());
    }
    check_key(&key, "That code no longer works. Request a new one.").await?;
    Ok(Redeemed::Code { key, account_id: account_id.to_string() })
}

/// Save a redeemed key. Entering another code switches to its credit.
pub(crate) fn save_redeemed(db: &impl CloudDb, redeemed: &Redeemed) -> Result<(), String> {
    let (key, account_id) = match redeemed {
        Redeemed::Code { key, account_id } => (key.as_str(), account_id.as_str()),
        Redeemed::OwnKey { key } => (key.as_str(), OWN_KEY),
    };
    db.with_db(|conn| db::save_activation(conn, key, account_id))
        .map_err(|_| "Could not save the activation".to_string())
}

/// The account and key to ask the credit service about, or `None` for no code
/// or for the user's own key, which the service must never see.
pub(crate) fn balance_query(db: &impl CloudDb) -> Result<Option<(Zeroizing<String>, String)>, String> {
    Ok(stored(db)?.filter(|(_, id)| id != OWN_KEY))
}

/// Ask the credit service about a code's standing.
pub(crate) async fn fetch_balance(key: &str, account_id: &str) -> Result<Value, String> {
    post("/v1/balance", json!({ "accountId": account_id }), Some(key)).await
}

/// Read the service's reply against the recorded run-out.
pub(crate) fn settle_balance(db: &impl CloudDb, reply: &Value) -> CreditBalance {
    let upgrade_url = reply["upgradeUrl"]
        .as_str()
        .filter(|url| url::Url::parse(url).is_ok_and(|u| u.scheme() == "https"))
        .map(str::to_string);
    let expires_at = reply["expiresAt"]
        .as_str()
        .filter(|at| DateTime::parse_from_rfc3339(at).is_ok())
        .map(str::to_string);
    // The key's spend limit now, which paying raises.
    let granted_nano = reply["grantedNano"].as_f64().map(|nano| nano as i64);
    let credit_used_up = settle_run_out(db, granted_nano).unwrap_or_else(|error| {
        log::warn!("Could not settle the private cloud credit run-out: {error}");
        true
    });
    CreditBalance {
        payment_pending: reply["pendingNano"].as_f64().is_some_and(|nano| nano > 0.0),
        expires_at,
        disabled: reply["disabled"].as_bool().unwrap_or(false),
        upgrade_url,
        credit_used_up,
    }
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::sync::Mutex;

    /// An unencrypted in-memory database stands in for the vault.
    pub(crate) struct MemoryDb(Mutex<Connection>);

    impl MemoryDb {
        pub(crate) fn new() -> Self {
            Self(Mutex::new(Connection::open_in_memory().unwrap()))
        }
    }

    impl CloudDb for MemoryDb {
        fn with_db<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
            f(&self.0.lock().unwrap()).map_err(|e| e.to_string())
        }
    }

    #[test]
    fn only_near_ai_keys_are_kept() {
        assert!(well_formed_key("sk-0123456789abcdef0123456789abcdef"));
        for key in ["", "sk-1", "not-a-key-at-all", "sk-has spaces in it", "Bearer sk-0123456789abcdef"] {
            assert!(!well_formed_key(key), "{key:?}");
        }
    }

    #[test]
    fn a_rejected_key_reads_as_credit_used_up() {
        let rejected = format!("{} (HTTP 402)", super::super::KEY_REJECTED);
        assert_eq!(run_error(rejected), CREDIT_USED_UP);
        assert_eq!(run_error("Attestation failed".into()), "Attestation failed");
    }

    fn redeemed_db() -> MemoryDb {
        let db = MemoryDb::new();
        // Before a code is redeemed there is no key, so private cloud runs
        // fail with NO_ACTIVATION.
        assert!(key(&db).unwrap().is_none());
        db.with_db(|c| db::save_activation(c, "sk-0123456789abcdef", "id-1")).unwrap();
        assert_eq!(key(&db).unwrap().as_deref().map(String::as_str), Some("sk-0123456789abcdef"));
        db
    }

    fn used_up(db: &MemoryDb) -> bool {
        db.with_db(db::get_run_out).unwrap().is_some()
    }

    fn run_out(db: &MemoryDb) -> Option<(String, Option<i64>)> {
        db.with_db(db::get_run_out).unwrap()
    }

    #[tokio::test]
    async fn an_own_key_is_saved_without_an_account() {
        let db = MemoryDb::new();
        // Refused before NEAR AI is asked.
        assert!(redeem("sk-1").await.is_err());
        assert!(key(&db).unwrap().is_none());
        save_redeemed(&db, &Redeemed::OwnKey { key: Zeroizing::new("sk-0123456789abcdef".into()) }).unwrap();
        let (saved, id) = stored(&db).unwrap().unwrap();
        assert_eq!((saved.as_str(), id.as_str()), ("sk-0123456789abcdef", OWN_KEY));
        // Never mistaken for an account the service issued, and never sent to it.
        assert!(!well_formed_account_id(OWN_KEY));
        assert!(balance_query(&db).unwrap().is_none());
        assert!(status(&db).unwrap().own_key);
    }

    #[tokio::test]
    async fn malformed_codes_are_refused_before_anything_is_sent() {
        for code in ["", "   ", &"x".repeat(65)] {
            assert_eq!(redeem(code).await.err().as_deref(), Some("That code isn't valid."), "{code:?}");
        }
    }

    #[test]
    fn a_raised_limit_or_a_new_code_clears_the_run_out() {
        let db = redeemed_db();
        assert!(!settle_run_out(&db, Some(5)).unwrap());

        remember_credit_used_up(&db);
        // The first check saves the baseline; the same limit keeps the run-out.
        assert!(settle_run_out(&db, Some(5)).unwrap());
        assert_eq!(run_out(&db).unwrap().1, Some(5));
        assert!(settle_run_out(&db, Some(5)).unwrap());
        assert!(settle_run_out(&db, None).unwrap());
        // Paying raised it.
        assert!(!settle_run_out(&db, Some(6)).unwrap());
        assert!(!used_up(&db));

        // A new run-out starts over, without the old baseline.
        remember_credit_used_up(&db);
        assert_eq!(run_out(&db).unwrap().1, None);
        assert!(settle_run_out(&db, Some(6)).unwrap());
        save_redeemed(
            &db,
            &Redeemed::Code { key: Zeroizing::new("sk-fedcba9876543210".into()), account_id: "id-2".into() },
        )
        .unwrap();
        assert!(!used_up(&db));
    }

    #[test]
    fn only_a_run_started_after_the_run_out_clears_it() {
        let at = Utc::now();
        let stored = at.to_rfc3339_opts(SecondsFormat::Nanos, true);
        assert!(!run_clears_run_out(at - chrono::Duration::seconds(1), &stored));
        assert!(!run_clears_run_out(at, &stored));
        assert!(run_clears_run_out(at + chrono::Duration::nanoseconds(1), &stored));
    }

    #[test]
    fn a_success_clears_the_run_out_only_for_a_later_run() {
        let db = redeemed_db();
        let before = Utc::now();
        remember_credit_used_up(&db);
        remember_credit_works(&db, before);
        assert!(used_up(&db));
        remember_credit_works(&db, Utc::now());
        assert!(!used_up(&db));
    }

    #[test]
    fn account_ids_are_uuids_not_anything_the_service_sends() {
        assert!(well_formed_account_id("5b737ca6-a4c7-488e-b928-8452960c4be9"));
        for id in ["", "../settings", "id with spaces", &"a".repeat(65)] {
            assert!(!well_formed_account_id(id), "{id:?}");
        }
    }

    #[test]
    fn the_balance_reply_is_read_defensively() {
        let db = redeemed_db();
        let reply = json!({
            "grantedNano": 5e9, "pendingNano": 1e9, "expiresAt": "not a date",
            "disabled": true, "upgradeUrl": "http://insecure.example/pay",
        });
        let balance = settle_balance(&db, &reply);
        assert!(balance.payment_pending && balance.disabled && !balance.credit_used_up);
        assert_eq!(balance.expires_at, None);
        assert_eq!(balance.upgrade_url, None, "only https upgrade links are passed on");
    }
}
