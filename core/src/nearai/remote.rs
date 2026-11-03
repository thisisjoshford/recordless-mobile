//! Hardware attestation checks that need a third party: Intel's collateral
//! for TDX quotes and NVIDIA's attestation service for the GPUs.
//!
//! Only attestation evidence is sent to these services, never meeting content.
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use dcap_qvl::quote::Quote;
use dcap_qvl::verify::{QuoteVerifier, VerifiedReport};
use dcap_qvl::QuoteCollateralV3;
use once_cell::sync::Lazy;
use serde::Deserialize;
use serde_json::value::RawValue;
use sha2::Digest;
use x509_parser::extensions::{DistributionPointName, GeneralName, ParsedExtension};

const INTEL_PCS: &str = "https://api.trustedservices.intel.com";
const NRAS_ATTEST_URL: &str = "https://nras.attestation.nvidia.com/v3/attest/gpu";
const NRAS_JWKS_URL: &str = "https://nras.attestation.nvidia.com/.well-known/jwks.json";
const NRAS_ISSUER: &str = "https://nras.attestation.nvidia.com";
const HTTP_TIMEOUT: Duration = Duration::from_secs(60);
/// Intel collateral and NVIDIA's signing keys change rarely. Reusing them for a
/// while keeps verification quick; both are still checked cryptographically.
const CACHE_TTL: Duration = Duration::from_secs(60 * 60);

/// Platform collateral by "fmspc/ca", without the per-quote PCK chain.
static COLLATERAL_CACHE: Lazy<Mutex<HashMap<String, (Instant, QuoteCollateralV3)>>> =
    Lazy::new(|| Mutex::new(HashMap::new()));
static NVIDIA_KEYS_CACHE: Lazy<Mutex<Option<(Instant, jsonwebtoken::jwk::JwkSet)>>> =
    Lazy::new(|| Mutex::new(None));

/// TCB levels we accept. `OutOfDate` means Intel has published advisories the
/// host has not yet patched; the quote itself is still genuine. The status is
/// reported to the user either way.
const ACCEPTED_TCB_STATUS: &[&str] = &["UpToDate", "SWHardeningNeeded", "OutOfDate"];

fn http() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(HTTP_TIMEOUT)
        .build()
        .map_err(|e| format!("HTTP client setup failed: {e}"))
}

async fn get(client: &reqwest::Client, url: &str) -> Result<reqwest::Response, String> {
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|e| format!("Could not reach {url}: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("{url} returned HTTP {}", response.status()));
    }
    Ok(response)
}

/// Read a response body, refusing anything past `limit` without allocating
/// it. Collateral and compose files are tens of kilobytes; nothing here is
/// large, and none of these sources is trusted for its size. Also used by
/// `feedback` for the form service's reply.
pub(crate) async fn body_within(mut response: reqwest::Response, limit: usize) -> Result<Vec<u8>, String> {
    let url = response.url().to_string();
    if response.content_length().is_some_and(|length| length > limit as u64) {
        return Err(format!("{url} returned more data than expected"));
    }
    let mut body = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| format!("Could not read {url}: {e}"))?
    {
        if body.len() + chunk.len() > limit {
            return Err(format!("{url} returned more data than expected"));
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

/// Intel's collateral: certificate chains, CRLs and TCB info.
const COLLATERAL_LIMIT: usize = 1 << 20;

async fn text_within(response: reqwest::Response, limit: usize) -> Result<String, String> {
    let url = response.url().to_string();
    let body = body_within(response, limit).await?;
    String::from_utf8(body).map_err(|_| format!("{url} did not return text"))
}

fn header(response: &reqwest::Response, names: &[&str]) -> Result<String, String> {
    let value = names
        .iter()
        .find_map(|name| response.headers().get(*name))
        .ok_or_else(|| format!("Intel PCS response is missing {}", names[0]))?;
    let value = value.to_str().map_err(|_| format!("Invalid {} header", names[0]))?;
    urlencoding::decode(value)
        .map(|v| v.into_owned())
        .map_err(|_| format!("Invalid {} header", names[0]))
}

#[derive(Deserialize)]
struct TcbInfoResponse<'a> {
    #[serde(rename = "tcbInfo", borrow)]
    tcb_info: &'a RawValue,
    signature: String,
}

#[derive(Deserialize)]
struct QeIdentityResponse<'a> {
    #[serde(rename = "enclaveIdentity", borrow)]
    enclave_identity: &'a RawValue,
    signature: String,
}

fn pem_chain_ders(pem_chain: &[u8]) -> Result<Vec<Vec<u8>>, String> {
    x509_parser::pem::Pem::iter_from_buffer(pem_chain)
        .map(|pem| pem.map(|p| p.contents).map_err(|e| format!("Invalid PEM chain: {e}")))
        .collect()
}

fn crl_url(cert_der: &[u8]) -> Result<String, String> {
    let (_, cert) = x509_parser::parse_x509_certificate(cert_der)
        .map_err(|e| format!("Invalid Intel root certificate: {e}"))?;
    for ext in cert.extensions() {
        if let ParsedExtension::CRLDistributionPoints(points) = ext.parsed_extension() {
            for point in points.iter() {
                if let Some(DistributionPointName::FullName(names)) = &point.distribution_point {
                    for name in names {
                        if let GeneralName::URI(uri) = name {
                            return Ok(uri.to_string());
                        }
                    }
                }
            }
        }
    }
    Err("Intel root certificate has no CRL distribution point".into())
}

/// Fetch Intel collateral for a TDX quote that embeds its PCK chain.
pub(crate) async fn fetch_collateral(raw_quote: &[u8]) -> Result<QuoteCollateralV3, String> {
    let quote = Quote::parse(raw_quote).map_err(|e| format!("Invalid TDX quote: {e}"))?;
    let pck_chain = quote
        .raw_cert_chain()
        .map_err(|e| format!("TDX quote has no PCK chain: {e}"))?;
    let pck_ders = pem_chain_ders(pck_chain)?;
    let leaf = pck_ders.first().ok_or("TDX quote has an empty PCK chain")?;
    let fmspc = hex::encode_upper(
        dcap_qvl::intel::parse_pck_extension(leaf)
            .map_err(|e| format!("Invalid PCK certificate: {e}"))?
            .fmspc,
    );
    let (_, leaf_cert) = x509_parser::parse_x509_certificate(leaf)
        .map_err(|e| format!("Invalid PCK certificate: {e}"))?;
    let ca = if leaf_cert.issuer().to_string().contains("Platform CA") { "platform" } else { "processor" };
    let pck_certificate_chain = Some(String::from_utf8_lossy(pck_chain).into_owned());

    let cache_key = format!("{fmspc}/{ca}");
    let cached = COLLATERAL_CACHE.lock().ok().and_then(|cache| {
        cache
            .get(&cache_key)
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, collateral)| collateral.clone())
    });
    if let Some(collateral) = cached {
        return Ok(QuoteCollateralV3 { pck_certificate_chain, ..collateral });
    }

    let client = http()?;
    let pck = get(&client, &format!("{INTEL_PCS}/sgx/certification/v4/pckcrl?ca={ca}&encoding=der")).await?;
    let pck_crl_issuer_chain = header(&pck, &["SGX-PCK-CRL-Issuer-Chain"])?;
    let pck_crl = body_within(pck, COLLATERAL_LIMIT).await?;

    let tcb = get(&client, &format!("{INTEL_PCS}/tdx/certification/v4/tcb?fmspc={fmspc}&update=standard")).await?;
    let tcb_info_issuer_chain = header(&tcb, &["SGX-TCB-Info-Issuer-Chain", "TCB-Info-Issuer-Chain"])?;
    let tcb_body = text_within(tcb, COLLATERAL_LIMIT).await?;
    let tcb: TcbInfoResponse = serde_json::from_str(&tcb_body).map_err(|e| format!("Invalid TCB info: {e}"))?;

    let qe = get(&client, &format!("{INTEL_PCS}/tdx/certification/v4/qe/identity?update=standard")).await?;
    let qe_identity_issuer_chain = header(&qe, &["SGX-Enclave-Identity-Issuer-Chain"])?;
    let qe_body = text_within(qe, COLLATERAL_LIMIT).await?;
    let qe: QeIdentityResponse = serde_json::from_str(&qe_body).map_err(|e| format!("Invalid QE identity: {e}"))?;

    let root = pem_chain_ders(qe_identity_issuer_chain.as_bytes())?;
    let root = root.last().ok_or("Intel QE identity chain is empty")?;
    // The CRL location comes out of a chain that is not verified yet, so
    // this read is bounded like the rest.
    let root_ca_crl =
        body_within(get(&client, &crl_url(root)?).await?, COLLATERAL_LIMIT).await?;

    let collateral = QuoteCollateralV3 {
        pck_crl_issuer_chain,
        root_ca_crl,
        pck_crl,
        tcb_info_issuer_chain,
        tcb_info: tcb.tcb_info.get().to_string(),
        tcb_info_signature: hex::decode(&tcb.signature).map_err(|_| "Invalid TCB info signature")?,
        qe_identity_issuer_chain,
        qe_identity: qe.enclave_identity.get().to_string(),
        qe_identity_signature: hex::decode(&qe.signature).map_err(|_| "Invalid QE identity signature")?,
        pck_certificate_chain: None,
    };
    if let Ok(mut cache) = COLLATERAL_CACHE.lock() {
        cache.insert(cache_key, (Instant::now(), collateral.clone()));
    }
    Ok(QuoteCollateralV3 { pck_certificate_chain, ..collateral })
}

async fn nvidia_key(client: &reqwest::Client, kid: &str) -> Result<jsonwebtoken::DecodingKey, String> {
    let cached = NVIDIA_KEYS_CACHE.lock().ok().and_then(|cache| {
        cache
            .as_ref()
            .filter(|(at, _)| at.elapsed() < CACHE_TTL)
            .map(|(_, keys)| keys.clone())
    });
    // NVIDIA rotates keys often, so an unknown key id triggers a refresh.
    let keys = match cached.filter(|keys| keys.find(kid).is_some()) {
        Some(keys) => keys,
        None => {
            let body = body_within(get(client, NRAS_JWKS_URL).await?, COLLATERAL_LIMIT).await?;
            let keys: jsonwebtoken::jwk::JwkSet = serde_json::from_slice(&body)
                .map_err(|e| format!("Invalid NVIDIA key set: {e}"))?;
            if let Ok(mut cache) = NVIDIA_KEYS_CACHE.lock() {
                *cache = Some((Instant::now(), keys.clone()));
            }
            keys
        }
    };
    let jwk = keys.find(kid).ok_or("NVIDIA token was signed by an unknown key")?;
    jsonwebtoken::DecodingKey::from_jwk(jwk).map_err(|e| format!("Invalid NVIDIA key: {e}"))
}

/// Verify a TDX quote against Intel's root of trust. Debug TDs are rejected by
/// the verifier.
pub(crate) fn verify_quote(raw_quote: &[u8], collateral: &QuoteCollateralV3) -> Result<VerifiedReport, String> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|_| "System clock is before 1970")?
        .as_secs();
    let report = QuoteVerifier::new_prod()
        .verify(raw_quote, collateral, now)
        .map_err(|e| format!("Intel TDX quote did not verify: {e:#}"))?;
    if !ACCEPTED_TCB_STATUS.contains(&report.status.as_str()) {
        return Err(format!("Intel TDX platform status is {}", report.status));
    }
    Ok(report)
}

#[derive(Deserialize)]
struct NrasClaims {
    #[serde(rename = "x-nvidia-overall-att-result")]
    overall_result: bool,
    eat_nonce: String,
}

/// Verify the GPU evidence with NVIDIA and return how many GPUs it covers.
pub(crate) async fn verify_gpus(nvidia_payload: &str, nonce_hex: &str) -> Result<usize, String> {
    let payload: serde_json::Value =
        serde_json::from_str(nvidia_payload).map_err(|e| format!("Invalid GPU evidence: {e}"))?;
    let payload_nonce = payload["nonce"].as_str().unwrap_or_default();
    if !payload_nonce.eq_ignore_ascii_case(nonce_hex) {
        return Err("GPU evidence was not produced for this request".into());
    }
    let gpu_count = payload["evidence_list"].as_array().map_or(0, Vec::len);
    if gpu_count == 0 {
        return Err("GPU evidence lists no GPUs".into());
    }

    let client = http()?;
    let response = client
        .post(NRAS_ATTEST_URL)
        .header("content-type", "application/json")
        .body(nvidia_payload.to_string())
        .send()
        .await
        .map_err(|e| format!("Could not reach NVIDIA attestation: {e}"))?;
    if !response.status().is_success() {
        return Err(format!("NVIDIA attestation returned HTTP {}", response.status()));
    }
    let body = body_within(response, COLLATERAL_LIMIT).await?;
    let body: serde_json::Value =
        serde_json::from_slice(&body).map_err(|e| format!("Invalid NVIDIA response: {e}"))?;
    let token = body[0][1].as_str().ok_or("NVIDIA response has no attestation token")?;

    let kid = jsonwebtoken::decode_header(token)
        .map_err(|e| format!("Invalid NVIDIA token: {e}"))?
        .kid
        .ok_or("NVIDIA token has no key id")?;
    let key = nvidia_key(&client, &kid).await?;
    let mut validation = jsonwebtoken::Validation::new(jsonwebtoken::Algorithm::ES384);
    validation.set_issuer(&[NRAS_ISSUER]);
    validation.validate_aud = false;
    let claims = jsonwebtoken::decode::<NrasClaims>(token, &key, &validation)
        .map_err(|e| format!("NVIDIA token did not verify: {e}"))?
        .claims;
    if !claims.overall_result {
        return Err("NVIDIA reports the GPU attestation failed".into());
    }
    if !claims.eat_nonce.eq_ignore_ascii_case(nonce_hex) {
        return Err("NVIDIA token is for a different request".into());
    }
    Ok(gpu_count)
}

/// Why a deployed compose file could not be used.
pub(crate) enum ComposeError {
    /// GitHub could not be reached, or does not have this file any more. This
    /// leaves the deployment unread; it does not disprove anything about it.
    Unreadable(String),
    /// The file came back, but not the file the enclave signed for.
    Tampered(String),
}

/// Deployed compose files by content hash. The hash comes from the enclave's
/// signed deploy log, so a cached file can be neither stale nor substituted.
static COMPOSE_CACHE: Lazy<Mutex<HashMap<String, String>>> = Lazy::new(|| Mutex::new(HashMap::new()));

const COMPOSE_REPO: &str = "https://raw.githubusercontent.com/nearai/cvm-compose-files";
const COMPOSE_LIMIT: usize = 1 << 20;
/// Every redeployment mints a new hash, so the cache would otherwise grow for
/// as long as the app runs.
const COMPOSE_CACHE_ENTRIES: usize = 64;

/// Fetch a compose file the deploy log recorded, and accept it only if it
/// hashes to what the enclave signed. GitHub therefore supplies the contents,
/// never the integrity: a substituted file fails the hash, and meeting content
/// is never involved.
pub(crate) async fn fetch_compose(
    commit: &str,
    path: &str,
    file_sha256: &str,
) -> Result<String, ComposeError> {
    let key = file_sha256.to_ascii_lowercase();
    if let Some(cached) = COMPOSE_CACHE.lock().ok().and_then(|cache| cache.get(&key).cloned()) {
        return Ok(cached);
    }
    if commit.len() != 40 || !commit.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ComposeError::Tampered(format!(
            "The deploy log names an unusable commit: {commit}"
        )));
    }
    let safe_path = !path.is_empty()
        && path.len() <= 200
        && (path.ends_with(".yaml") || path.ends_with(".yml"))
        && !path.starts_with('/')
        && !path.split('/').any(|segment| segment.is_empty() || segment == "." || segment == "..")
        && path.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_' | '/'));
    if !safe_path || key.len() != 64 || !key.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ComposeError::Tampered(format!(
            "The deploy log names an unusable compose file: {path}"
        )));
    }

    let client = http().map_err(ComposeError::Unreadable)?;
    let response = get(&client, &format!("{COMPOSE_REPO}/{commit}/{path}"))
        .await
        .map_err(ComposeError::Unreadable)?;
    let body = body_within(response, COMPOSE_LIMIT)
        .await
        .map_err(ComposeError::Unreadable)?;
    if hex::encode(sha2::Sha256::digest(&body)) != key {
        return Err(ComposeError::Tampered(format!(
            "{path} at {commit} is not the file the enclave signed for"
        )));
    }
    let text =
        String::from_utf8(body).map_err(|_| ComposeError::Tampered(format!("{path} is not text")))?;
    if let Ok(mut cache) = COMPOSE_CACHE.lock() {
        if cache.len() >= COMPOSE_CACHE_ENTRIES {
            cache.clear();
        }
        cache.insert(key, text.clone());
    }
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Everything `fetch_compose` refuses before it reaches the network. The
    /// commit and path come from the deploy log, so they are checked rather
    /// than pasted into a URL.
    #[tokio::test]
    async fn a_compose_file_is_only_fetched_from_a_checkable_place() {
        let sha = "a".repeat(64);
        let commit = "b".repeat(40);
        for (commit, path) in [
            ("short", "prod/models.yaml"),
            ("../../etc/passwd", "prod/models.yaml"),
            (commit.as_str(), "../../../etc/passwd.yaml"),
            (commit.as_str(), "/etc/models.yaml"),
            (commit.as_str(), "prod/../models.yaml"),
            (commit.as_str(), "prod/models.txt"),
            (commit.as_str(), "prod/mo dels.yaml"),
            (commit.as_str(), ""),
        ] {
            let refused = fetch_compose(commit, path, &sha).await;
            assert!(
                matches!(refused, Err(ComposeError::Tampered(_))),
                "{commit} {path} should be refused before any request"
            );
        }
        // A hash that is not a hash cannot be matched against anything.
        assert!(matches!(
            fetch_compose(&commit, "prod/models.yaml", "nothex").await,
            Err(ComposeError::Tampered(_))
        ));
    }
}
