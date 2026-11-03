//! Private cloud activation on the vault: the NEAR AI key lives in the vault's
//! `private_cloud` table (see `nearai::activation`) and is never returned
//! across the FFI. Only the vault's connection is used here; its keying is
//! `vault.rs`'s business.


use rusqlite::Connection;

use super::Vault;
use crate::nearai::{self, activation};
use crate::notes::{cloud_models, CloudModel};
use crate::CoreError;

/// What Swift may know about the private cloud credit. Never the key.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CreditStatus {
    /// A code (or own key) is redeemed and stored in this vault.
    pub active: bool,
    /// This build can redeem activation codes (credit service URL compiled in).
    pub available: bool,
    /// The stored key is the user's own, not a code's (no credit service checks).
    pub own_key: bool,
    /// NEAR AI turned the key away for want of credit and nothing has cleared it.
    pub credit_used_up: bool,
    /// The credit service was asked during this call (only after a run-out).
    pub checked: bool,
    pub payment_pending: bool,
    /// RFC 3339, when the code's key stops working.
    pub expires_at: Option<String>,
    /// The code was turned off and its key revoked.
    pub disabled: bool,
    /// https link to add credit.
    pub upgrade_url: Option<String>,
    /// The credit service could not be asked (the rest is from the vault).
    pub check_error: Option<String>,
}

impl activation::CloudDb for Vault {
    fn with_db<T>(&self, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> Result<T, String> {
        self.with_conn(f).map_err(|e| e.to_string())
    }
}

fn cloud_err(msg: impl Into<String>) -> CoreError {
    CoreError::PrivateCloud { msg: msg.into() }
}

impl Vault {
    /// Fails with `InvalidState` when the vault is closed.
    fn ensure_open(&self) -> Result<(), CoreError> {
        self.with_conn(|_| Ok(()))
    }

    fn local_status(&self) -> Result<CreditStatus, CoreError> {
        let s = activation::status(self).map_err(cloud_err)?;
        Ok(CreditStatus {
            active: s.active,
            available: s.available,
            own_key: s.own_key,
            credit_used_up: s.credit_used_up,
            checked: false,
            payment_pending: false,
            expires_at: None,
            disabled: false,
            upgrade_url: None,
            check_error: None,
        })
    }
}

#[uniffi::export]
impl Vault {
    /// Redeem an activation code with Recordless's credit service, or
    /// (undocumented) save a NEAR AI key of the user's own (`sk-…`). Either key
    /// is saved in this vault only after NEAR AI accepts it. Blocking; makes
    /// network requests. The key is never returned.
    pub fn redeem_activation(&self, code: String) -> Result<CreditStatus, CoreError> {
        let code = zeroize::Zeroizing::new(code);
        self.ensure_open()?;
        let redeemed = nearai::runtime().block_on(activation::redeem(&code)).map_err(cloud_err)?;
        activation::save_redeemed(self, &redeemed).map_err(cloud_err)?;
        self.local_status()
    }

    /// The private cloud credit as stored. Asks the credit service (sending
    /// the code's account id and key, never content) only when the credit is
    /// recorded as used up and the key is a code's, as on desktop.
    pub fn private_cloud_status(&self) -> Result<CreditStatus, CoreError> {
        self.ensure_open()?;
        let mut status = self.local_status()?;
        if !(status.active && status.credit_used_up && status.available && !status.own_key) {
            return Ok(status);
        }
        let Some((key, account_id)) = activation::balance_query(self).map_err(cloud_err)? else {
            return Ok(status);
        };
        match nearai::runtime().block_on(activation::fetch_balance(&key, &account_id)) {
            Ok(reply) => {
                let balance = activation::settle_balance(self, &reply);
                status.checked = true;
                status.payment_pending = balance.payment_pending;
                status.expires_at = balance.expires_at;
                status.disabled = balance.disabled;
                status.upgrade_url = balance.upgrade_url;
                status.credit_used_up = balance.credit_used_up;
            }
            Err(error) => status.check_error = Some(error),
        }
        Ok(status)
    }

    /// Chat models NEAR AI serves from attested TEE hosts, suggestions first,
    /// the default flagged `recommended`. Needs no key. Listing is not
    /// verification: every request is attested before anything is sent.
    pub fn list_private_cloud_models(&self) -> Result<Vec<CloudModel>, CoreError> {
        let models = nearai::runtime().block_on(nearai::list_models()).map_err(cloud_err)?;
        Ok(cloud_models(&models))
    }
}

impl Vault {
    /// The stored NEAR AI key, for `Session::generate_notes` only.
    pub(crate) fn private_cloud_key(&self) -> Result<Option<zeroize::Zeroizing<String>>, CoreError> {
        activation::key(self).map_err(cloud_err)
    }
}
