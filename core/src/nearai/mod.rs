//! NEAR AI Cloud as a notes model, used only when it proves it runs in a TEE.
//!
//! Every request opens a fresh connection to the model host and, before any
//! meeting text is sent, verifies on that same connection:
//! - an Intel TDX quote (genuine hardware, not a debug TD, acceptable TCB);
//! - that the quote binds this request's nonce, the TLS key of this
//!   connection, and the key that signs responses;
//! - that the host is serving the requested model;
//! - the measured deployment manifest (private logs, attested key service,
//!   digest-pinned images) and the boot event log;
//! - NEAR's deploy-manager log, bound to its own quote from the same enclave;
//! - NVIDIA's verdict on the GPU evidence for this nonce.
//! The response must then be signed by the attested key.
//!
//! Ported from desktop `summary/nearai/mod.rs`. The checks are unchanged; only
//! the Tauri commands and events are replaced by the UniFFI surface in
//! `crate::cloud` and `crate::vault`.
pub mod activation;
mod channel;
mod evidence;
pub(crate) mod remote;

use std::collections::BTreeMap;
use std::time::Duration;

use hyper::Method;
use log::info;
use serde::{Deserialize, Serialize};

use channel::Channel;
use evidence::{AttestationReport, ChatSignature};

const ENDPOINTS_URL: &str = "https://completions.near.ai/endpoints";
const CATALOGUE_URL: &str = "https://cloud-api.near.ai/v1/model/list";
const HOST_SUFFIX: &str = ".completions.near.ai";
/// NEAR AI checks the key before the request, so a request naming no model and
/// no messages is refused as incomplete (HTTP 400) for a key it accepts and as
/// unauthorised for one it doesn't. Nothing runs and no credit is spent.
const KEY_CHECK_URL: &str = "https://cloud-api.near.ai/v1/chat/completions";
/// Statuses with which a model host turns the API key away: unknown or revoked,
/// out of credit, or not allowed.
const KEY_REJECTED_STATUSES: [u16; 3] = [401, 402, 403];
/// Stable start of the error for a rejected key, matched in `service.rs`.
pub const KEY_REJECTED: &str = "NEAR AI did not accept the API key";
const NON_CHAT_MODELS: &[&str] = &["embedding", "reranker", "whisper", "flux", "privacy-filter"];
/// Anything shorter can't hold a meeting transcript.
const MIN_CONTEXT_TOKENS: u64 = 65_536;
/// Context kept free for the instructions and the generated notes.
const RESERVED_CONTEXT_TOKENS: u64 = 20_000;
const MAX_CHUNK_TOKENS: u64 = 100_000;
/// Used when the model's context length can't be looked up.
pub(crate) const FALLBACK_CHUNK_TOKENS: usize = 24_000;

/// Models we suggest for meeting notes, in display order: (id, label, reason).
/// A suggestion only appears while NEAR AI still hosts and attests the model.
const SUGGESTIONS: &[(&str, &str, &str)] = &[
    (
        "z-ai/glm-5.3-flash",
        "Recommended",
        "Handles very long meetings and leaves room for detailed notes, at a low price.",
    ),
    (
        "deepseek-ai/DeepSeek-V4-Flash",
        "Fastest and cheapest",
        "Quick, low-cost notes, even for very long meetings.",
    ),
    (
        "Qwen/Qwen3.8-27B",
        "Most thorough",
        "A larger dense model for careful notes on short to medium meetings. Costs more.",
    ),
    (
        "Qwen/Qwen3.6-35B-A3B-FP8",
        "Lightweight",
        "Fast and inexpensive for everyday meetings.",
    ),
];
const ATTESTATION_LIMIT: usize = 4 * 1024 * 1024;
const CHAT_LIMIT: usize = 4 * 1024 * 1024;
const ATTESTATION_TIMEOUT: Duration = Duration::from_secs(60);
/// The reply isn't streamed, so this covers the whole generation: a reasoning
/// model writing notes for an hour-long meeting can take well over five minutes.
const CHAT_TIMEOUT: Duration = Duration::from_secs(900);
const SIGNATURE_ATTEMPTS: u32 = 5;

/// Verification stages, in the order they run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Stage {
    Connect,
    Model,
    Hardware,
    Binding,
    Software,
    Deploy,
    Weights,
    Gpu,
}

impl Stage {
    pub const ALL: [Stage; 8] = [
        Stage::Connect,
        Stage::Model,
        Stage::Hardware,
        Stage::Binding,
        Stage::Software,
        Stage::Deploy,
        Stage::Weights,
        Stage::Gpu,
    ];
}

/// Records the stage in progress so a failure can be attributed to it.
pub(crate) struct Progress<'a> {
    pub stage: Stage,
    pub notify: &'a (dyn Fn(Stage) + Send + Sync),
    /// Stages left unread so far in this attestation (desktop: `skipped_stages`),
    /// kept here so a later failure can still report them.
    pub unread: Vec<Stage>,
}

impl Progress<'_> {
    fn enter(&mut self, stage: Stage) {
        self.stage = stage;
        (self.notify)(stage);
    }
}

/// Why a private cloud request did not complete.
#[derive(Debug, Clone)]
pub(crate) enum CloudError {
    /// Verification failed at `stage`; nothing but attestation traffic was sent.
    Verification { stage: Stage, error: String },
    /// The attested request itself failed, or its signature did not check out.
    /// `signature_failed` is set when the response was discarded for its signature.
    Request { report: Box<TeeReport>, error: String, signature_failed: bool },
}


/// The service that serves this model, as the deployed compose file defines it.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSource {
    pub service: String,
    /// The serving image of this service, and of any replica running a
    /// different build of it.
    pub images: Vec<String>,
    pub weights: String,
    /// The weights revision, when the deployment pins one.
    pub revision: Option<String>,
    pub compose_file: String,
    pub commit: String,
}

/// What was verified, safe to show in the UI and logs.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TeeReport {
    pub host: String,
    pub model: String,
    pub signing_address: String,
    pub tcb_status: String,
    pub advisory_ids: Vec<String>,
    pub gpu_count: usize,
    pub compose_hash: String,
    /// `None` when the host has no deploy log to check.
    pub deploy_actions: Option<usize>,
    pub tls_key_sha256: String,
    /// `None` when the deployment could not be read; see `skipped_stages`.
    pub model_source: Option<ModelSource>,
    pub skipped_stages: Vec<Stage>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NearAiModel {
    pub id: String,
    pub host: String,
    pub display_name: String,
    pub description: Option<String>,
    pub context_length: Option<u64>,
    pub max_output_tokens: Option<u64>,
    /// USD per million tokens.
    pub input_price: Option<f64>,
    pub output_price: Option<f64>,
    pub suggestion: Option<Suggestion>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Suggestion {
    pub label: &'static str,
    pub reason: &'static str,
}

#[derive(Deserialize)]
struct Catalogue {
    models: Vec<CatalogueModel>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CatalogueModel {
    model_id: String,
    input_cost_per_token: Option<Price>,
    output_cost_per_token: Option<Price>,
    #[serde(default)]
    metadata: CatalogueMetadata,
}

#[derive(Deserialize)]
struct Price {
    amount: i64,
    scale: u32,
}

impl Price {
    fn per_million(&self) -> f64 {
        self.amount as f64 * 1e6 / 10f64.powi(self.scale as i32)
    }
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct CatalogueMetadata {
    attestation_supported: bool,
    context_length: Option<u64>,
    max_output_length: Option<u64>,
    model_display_name: Option<String>,
    model_description: Option<String>,
    architecture: Option<Architecture>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct Architecture {
    input_modalities: Vec<String>,
    output_modalities: Vec<String>,
}

#[derive(Deserialize)]
struct Endpoints {
    endpoints: Vec<Endpoint>,
}

#[derive(Deserialize)]
struct Endpoint {
    domain: String,
    models: Vec<String>,
}

async fn fetch_json<T: serde::de::DeserializeOwned>(url: &str) -> Result<T, String> {
    reqwest::Client::new()
        .get(url)
        .timeout(Duration::from_secs(20))
        .send()
        .await
        .map_err(|e| format!("Could not reach NEAR AI: {e}"))?
        .error_for_status()
        .map_err(|e| format!("NEAR AI model list failed: {e}"))?
        .json()
        .await
        .map_err(|e| format!("Unexpected NEAR AI model list: {e}"))
}

/// Whether NEAR AI accepts an API key, asked without sending anything but the
/// key. `Err` means NEAR AI couldn't be asked.
pub async fn key_accepted(api_key: &str) -> Result<bool, String> {
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(20))
        .build()
        .map_err(|e| format!("Could not reach NEAR AI: {e}"))?;
    let status = client
        .post(KEY_CHECK_URL)
        .bearer_auth(api_key)
        .json(&serde_json::json!({ "messages": [] }))
        .send()
        .await
        .map_err(|e| format!("Could not reach NEAR AI: {e}"))?
        .status()
        .as_u16();
    key_check_result(status)
}

fn key_check_result(status: u16) -> Result<bool, String> {
    match status {
        400 => Ok(true),
        status if KEY_REJECTED_STATUSES.contains(&status) => Ok(false),
        status => Err(format!("NEAR AI could not check the key (HTTP {status})")),
    }
}

/// (model id, host) for every model served directly from a TEE host.
async fn tee_hosts() -> Result<Vec<(String, String)>, String> {
    let endpoints: Endpoints = fetch_json(ENDPOINTS_URL).await?;
    Ok(endpoints
        .endpoints
        .into_iter()
        .filter(|e| e.domain.ends_with(HOST_SUFFIX))
        .flat_map(|e| {
            let host = e.domain;
            e.models.into_iter().map(move |id| (id, host.clone()))
        })
        .collect())
}

fn is_usable_for_notes(id: &str, meta: &CatalogueMetadata) -> bool {
    let lower = id.to_ascii_lowercase();
    let text_only_output = meta
        .architecture
        .as_ref()
        .is_some_and(|a| a.output_modalities == ["text"] && a.input_modalities.iter().any(|m| m == "text"));
    meta.attestation_supported
        && text_only_output
        && meta.context_length.unwrap_or(0) >= MIN_CONTEXT_TOKENS
        && !NON_CHAT_MODELS.iter().any(|marker| lower.contains(marker))
}

/// Build the picker list: models that are both hosted on a TEE host and listed
/// in NEAR AI's catalogue as attested text models. Old alias names on the host
/// list are dropped because they are not catalogue entries. Suggestions first.
fn build_model_list(hosts: Vec<(String, String)>, catalogue: Catalogue) -> Vec<NearAiModel> {
    let mut models: Vec<NearAiModel> = catalogue
        .models
        .into_iter()
        .filter(|m| is_usable_for_notes(&m.model_id, &m.metadata))
        .filter_map(|m| {
            let host = hosts.iter().find(|(id, _)| *id == m.model_id)?.1.clone();
            let suggestion = SUGGESTIONS
                .iter()
                .find(|(id, _, _)| *id == m.model_id)
                .map(|(_, label, reason)| Suggestion { label, reason });
            Some(NearAiModel {
                display_name: m.metadata.model_display_name.unwrap_or_else(|| m.model_id.clone()),
                description: m.metadata.model_description,
                context_length: m.metadata.context_length,
                max_output_tokens: m.metadata.max_output_length,
                input_price: m.input_cost_per_token.as_ref().map(Price::per_million),
                output_price: m.output_cost_per_token.as_ref().map(Price::per_million),
                id: m.model_id,
                host,
                suggestion,
            })
        })
        .collect();
    let rank = |m: &NearAiModel| {
        SUGGESTIONS
            .iter()
            .position(|(id, _, _)| *id == m.id)
            .unwrap_or(SUGGESTIONS.len())
    };
    models.sort_by(|a, b| rank(a).cmp(&rank(b)).then_with(|| a.display_name.cmp(&b.display_name)));
    models.dedup_by(|a, b| a.id == b.id);
    models
}

/// Chat models NEAR AI serves from attested TEE hosts, suggestions first.
pub async fn list_models() -> Result<Vec<NearAiModel>, String> {
    let (hosts, catalogue) = tokio::try_join!(tee_hosts(), fetch_json::<Catalogue>(CATALOGUE_URL))?;
    Ok(build_model_list(hosts, catalogue))
}

/// Transcript chunk size for a context length. The app's token count is an
/// estimate, so only 80% of the free context is used.
pub(crate) fn chunk_tokens(context_length: u64) -> usize {
    (context_length.saturating_sub(RESERVED_CONTEXT_TOKENS) * 4 / 5).clamp(4_000, MAX_CHUNK_TOKENS) as usize
}

/// How much transcript to send per request for this model.
#[allow(dead_code)] // `notes::Run` reuses the model list it already fetched; kept for the live tests.
pub async fn chunk_tokens_for(model: &str) -> usize {
    match list_models().await {
        Ok(models) => models
            .iter()
            .find(|m| m.id == model)
            .and_then(|m| m.context_length)
            .map_or(FALLBACK_CHUNK_TOKENS, chunk_tokens),
        Err(_) => FALLBACK_CHUNK_TOKENS,
    }
}

/// Resolve the host for a model. Hosts only ever come from NEAR AI's raw host
/// list, so a model saved before it left the catalogue still reaches
/// verification (which then decides), and anything NEAR AI doesn't list, such
/// as a custom host saved by an older version, is refused.
async fn host_for(model: &str) -> Result<(String, String), String> {
    tee_hosts()
        .await?
        .into_iter()
        .find(|(id, _)| id == model)
        .map(|(_, host)| (host, model.to_string()))
        .ok_or_else(|| format!("NEAR AI does not list a TEE host for {model}"))
}

fn td_report(report: &dcap_qvl::quote::Report) -> Result<&dcap_qvl::quote::TDReport10, String> {
    match report {
        dcap_qvl::quote::Report::TD10(r) => Ok(r),
        dcap_qvl::quote::Report::TD15(r) => Ok(&r.base),
        dcap_qvl::quote::Report::SgxEnclave(_) => Err("Expected an Intel TDX quote".into()),
    }
}

fn same_enclave(a: &dcap_qvl::quote::TDReport10, b: &dcap_qvl::quote::TDReport10) -> bool {
    a.mr_td == b.mr_td
        && a.mr_config_id == b.mr_config_id
        && a.rt_mr0 == b.rt_mr0
        && a.rt_mr1 == b.rt_mr1
        && a.rt_mr2 == b.rt_mr2
        && a.rt_mr3 == b.rt_mr3
}

/// Deployments to look through before giving up. A host with more history than
/// this cannot be searched exhaustively, so the stage is left unread rather
/// than passed or failed on a partial view.
const MAX_DEPLOYMENTS: usize = 32;

/// Work out what the enclave is actually running for `model`: replay the deploy
/// log into what is live right now, fetch the compose file behind each part of
/// it (accepted only at the hash the enclave signed), and read back every
/// running service that serves this model.
///
/// All of them have to agree on the image and weights, since any of them could
/// be the one that answers. `Ok(None)` means the question could not be
/// answered, because there was too much history to search or because GitHub was
/// unreachable. Neither party can use that to lie: NEAR AI cannot reach your
/// network, and a network attacker cannot change what the enclave signed. A
/// file that fails its hash, or a model served from something the host can swap
/// at will, is an error.
async fn model_source(
    actions: &[serde_json::Value],
    model: &str,
) -> Result<Option<ModelSource>, String> {
    let running = evidence::running_services(actions);
    // Group by deployment so each compose file is read once.
    let mut named: BTreeMap<evidence::Deployment, Vec<String>> = BTreeMap::new();
    for (service, (_, deployment)) in &running.named {
        named.entry(deployment.clone()).or_default().push(service.clone());
    }
    let mut whole: Vec<(evidence::Deployment, Vec<String>)> = Vec::new();
    for file in running.whole.values() {
        // A file started as a whole runs every service it defines, except
        // those stopped since and those a later record started by name. An
        // earlier named record is not subtracted: this start may have replaced
        // it, and if it did not, that container is read from its own record.
        let mut gone: Vec<String> = file.stopped.iter().cloned().collect();
        gone.extend(
            running
                .named
                .iter()
                .filter(|(_, (at, _))| *at > file.at)
                .map(|(service, _)| service.clone()),
        );
        whole.push((file.deployment.clone(), gone));
    }
    let deployments: Vec<(evidence::Deployment, Vec<String>, bool)> = named
        .into_iter()
        .map(|(deployment, services)| (deployment, services, false))
        .chain(whole.into_iter().map(|(deployment, superseded)| (deployment, superseded, true)))
        .collect();
    if deployments.is_empty() || deployments.len() > MAX_DEPLOYMENTS {
        return Ok(None);
    }

    let mut fetches = tokio::task::JoinSet::new();
    for (deployment, services, whole_file) in deployments {
        fetches.spawn(async move {
            let file =
                remote::fetch_compose(&deployment.commit, &deployment.path, &deployment.file_sha256)
                    .await;
            (deployment, services, whole_file, file)
        });
    }

    let mut found: Vec<(evidence::Deployment, evidence::ModelService)> = Vec::new();
    let mut unread = None;
    while let Some(fetched) = fetches.join_next().await {
        let (deployment, services, whole_file, file) =
            fetched.map_err(|e| format!("Reading the deployment failed: {e}"))?;
        let file = match file {
            Ok(file) => file,
            Err(remote::ComposeError::Tampered(error)) => return Err(error),
            Err(remote::ComposeError::Unreadable(error)) => {
                // A file we cannot fetch is a gap in what we can see, not
                // evidence about what it contains.
                unread = Some(error);
                continue;
            }
        };
        let names: Vec<&str> = services.iter().map(String::as_str).collect();
        let scope = if whole_file {
            evidence::Scope::WholeFile(&names)
        } else {
            evidence::Scope::Named(&names)
        };
        let reading = evidence::find_model_services(&file, scope, model)?;
        if let Some(service) = reading.unreadable {
            unread = Some(format!("{service} in {} could not be read", deployment.path));
        }
        for service in reading.services {
            found.push((deployment.clone(), service));
        }
    }

    agree_on_source(found, unread, model)
}

/// Turn what every running service says into one answer, or refuse.
///
/// Which model is answering has to be unambiguous, so the weights and their
/// revision must agree. Replicas running different builds of the serving
/// engine is routine during a rollout and each build is still pinned by
/// digest, so those are reported together rather than refused.
fn agree_on_source(
    mut found: Vec<(evidence::Deployment, evidence::ModelService)>,
    unread: Option<String>,
    model: &str,
) -> Result<Option<ModelSource>, String> {
    // A stable order, so two verifications of the same host report the same
    // service rather than whichever fetch happened to finish last.
    found.sort_by(|(a, left), (b, right)| (a, &left.service).cmp(&(b, &right.service)));
    let Some((deployment, service)) = found.first().cloned() else {
        return match unread {
            Some(error) => {
                info!("Could not read every deployment on this host: {error}");
                Ok(None)
            }
            None => Err(format!("Nothing running in this enclave serves {model}")),
        };
    };
    // The same container appearing under two records means the log does not
    // say which definition it is running.
    let mut names: Vec<&str> = found.iter().map(|(_, service)| service.service.as_str()).collect();
    names.sort_unstable();
    let ambiguous = names.windows(2).any(|pair| pair[0] == pair[1]);
    if ambiguous {
        return Ok(None);
    }
    let named = |service: &evidence::ModelService| match &service.revision {
        Some(revision) => format!("{} at {revision}", service.weights),
        None => format!("{} at no fixed version", service.weights),
    };
    if let Some((_, other)) = found
        .iter()
        .find(|(_, other)| (&other.weights, &other.revision) != (&service.weights, &service.revision))
    {
        return Err(format!(
            "Two services are serving {model} from different weights: {} and {}",
            named(&service),
            named(other)
        ));
    }
    if unread.is_some() {
        // Something else might also be serving this model, unseen.
        return Ok(None);
    }
    let mut images: Vec<String> = found.into_iter().map(|(_, service)| service.image).collect();
    images.sort();
    images.dedup();
    Ok(Some(ModelSource {
        service: service.service,
        images,
        weights: service.weights,
        revision: service.revision,
        compose_file: deployment.path,
        commit: deployment.commit,
    }))
}

async fn attest(
    channel: &mut Channel,
    host: &str,
    model: &str,
    progress: &mut Progress<'_>,
) -> Result<(TeeReport, String), String> {
    progress.unread.clear();
    progress.enter(Stage::Model);
    let nonce: [u8; 32] = rand::random();
    let nonce_hex = hex::encode(nonce);
    let response = channel
        .send(
            Method::GET,
            &format!("/v1/attestation/report?include_tls_fingerprint=true&signing_algo=ecdsa&nonce={nonce_hex}"),
            None,
            None,
            ATTESTATION_LIMIT,
            ATTESTATION_TIMEOUT,
        )
        .await?;
    if response.status != 200 {
        return Err(format!("{host} returned HTTP {} for its attestation", response.status));
    }
    let report: AttestationReport = serde_json::from_slice(&response.body)
        .map_err(|e| format!("{host} returned an unexpected attestation: {e}"))?;

    if report.model_name != model {
        return Err(format!("{host} is serving {}, not {model}", report.model_name));
    }
    if report.signing_algo != "ecdsa" {
        return Err("Unexpected response signing algorithm".into());
    }

    progress.enter(Stage::Hardware);
    let quote = hex::decode(&report.intel_quote).map_err(|_| "The TDX quote is not valid hex")?;
    let collateral = remote::fetch_collateral(&quote).await?;
    let verified = remote::verify_quote(&quote, &collateral)?;
    let td = td_report(&verified.report)?;

    progress.enter(Stage::Binding);
    let tls_key = hex::encode(channel.spki_sha256());
    if !report.tls_cert_fingerprint.eq_ignore_ascii_case(&tls_key) {
        return Err("This connection's TLS key is not the attested one".into());
    }
    evidence::check_report_data(&td.report_data, &report.signing_address, &report.tls_cert_fingerprint, &nonce)?;

    progress.enter(Stage::Software);
    let events = evidence::replay_rtmr3(&report.info.tcb_info.event_log, &td.rt_mr3)?;
    let compose_hash = evidence::check_app_compose(&report.info.tcb_info.app_compose, &td.mr_config_id, &events)?;

    progress.enter(Stage::Deploy);
    let mut unmeasured_manager = false;
    let deploy_actions = match &report.compose_manager_attestation {
        Some(cm) => {
            let cm_quote = hex::decode(&cm.quote).map_err(|_| "The deploy log quote is not valid hex")?;
            let cm_verified = remote::verify_quote(&cm_quote, &collateral)?;
            let cm_td = td_report(&cm_verified.report)?;
            if !same_enclave(td, cm_td) {
                return Err("The deploy log comes from a different enclave".into());
            }
            let measured = evidence::measured_manager_images(&report.info.tcb_info.app_compose);
            let (actions, manager_measured) =
                evidence::check_compose_manager(cm, &cm_td.report_data, &nonce, &measured)?;
            if !manager_measured {
                // The log is genuine, but what chose the manager that wrote it
                // was not measured, so it is read as a gap rather than proof.
                progress.unread.push(Stage::Deploy);
                unmeasured_manager = true;
            }
            Some(actions)
        }
        // Only NEAR AI's hosts run its deploy manager; elsewhere there is no
        // deploy log, and the measured manifest above is what was checked.
        None if !host.ends_with(HOST_SUFFIX) => {
            progress.unread.push(Stage::Deploy);
            None
        }
        None => return Err("This NEAR AI host did not return its deploy log".into()),
    };

    progress.enter(Stage::Weights);
    let model_source = match &report.compose_manager_attestation {
        // Nothing the log says about deployments can be relied on when an
        // unmeasured manager wrote it.
        Some(_) if unmeasured_manager => {
            progress.unread.push(Stage::Weights);
            None
        }
        Some(cm) => {
            let source = model_source(&cm.actions, model).await?;
            // Weights with no revision behind them are the repo's current
            // contents, which can change; that is read, not pinned.
            if source.as_ref().map_or(true, |source| source.revision.is_none()) {
                progress.unread.push(Stage::Weights);
            }
            source
        }
        // No deploy log, so nothing says which image is serving the model.
        None => {
            progress.unread.push(Stage::Weights);
            None
        }
    };

    progress.enter(Stage::Gpu);
    let gpu_count = remote::verify_gpus(&report.nvidia_payload, &nonce_hex).await?;

    let tee = TeeReport {
        host: host.to_string(),
        model: model.to_string(),
        signing_address: report.signing_address.clone(),
        tcb_status: verified.status.clone(),
        advisory_ids: verified.advisory_ids.clone(),
        gpu_count,
        compose_hash: hex::encode(compose_hash),
        deploy_actions,
        tls_key_sha256: tls_key,
        model_source,
        skipped_stages: progress.unread.clone(),
    };
    info!(
        "Secure enclave verified: host={} model={} tcb={} gpus={} compose={} images={} skipped={:?}",
        tee.host,
        tee.model,
        tee.tcb_status,
        tee.gpu_count,
        tee.compose_hash,
        tee.model_source
            .as_ref()
            .map_or_else(|| "unread".to_string(), |source| source.images.join(", ")),
        tee.skipped_stages
    );
    Ok((tee, report.signing_address))
}

#[allow(dead_code)]
pub(crate) fn ignore_progress(_: Stage) {}

/// The runtime every private cloud call runs on. The FFI is blocking, so each
/// call `block_on`s here from the caller's (background) thread.
pub(crate) fn runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("recordless-cloud")
            .enable_all()
            .build()
            .expect("the private cloud runtime starts")
    })
}

async fn open_and_attest(model: &str, progress: &mut Progress<'_>) -> Result<(Channel, TeeReport, String), String> {
    progress.enter(Stage::Connect);
    let (host, model) = host_for(model).await?;
    let mut channel = Channel::open(&host).await?;
    let (report, signing_address) = attest(&mut channel, &host, &model, progress).await?;
    Ok((channel, report, signing_address))
}

/// Run the full verification without sending anything else.
#[allow(dead_code)] // no FFI entry point yet; used by the opt-in live tests.
pub async fn verify_model(model: &str) -> Result<TeeReport, String> {
    let mut progress = Progress { stage: Stage::Connect, notify: &ignore_progress, unread: Vec::new() };
    open_and_attest(model, &mut progress).await.map(|(_, report, _)| report)
}

/// Send an OpenAI-style chat request to a verified enclave and return the raw
/// response body once its signature checks out, with what was verified.
pub(crate) async fn chat_completion(
    model: &str,
    api_key: &str,
    request_body: Vec<u8>,
    progress: &mut Progress<'_>,
) -> Result<(Vec<u8>, TeeReport), CloudError> {
    let verification = |progress: &Progress<'_>, e: String| CloudError::Verification {
        stage: progress.stage,
        error: format!("NEAR AI TEE verification failed, nothing was sent: {e}"),
    };
    let (mut channel, mut report, mut signing_address) =
        open_and_attest(model, progress).await.map_err(|e| verification(progress, e))?;
    // Verification talks to Intel and NVIDIA, and on a slow network the host may
    // close the idle connection meanwhile. The prompt may only travel over a
    // verified connection, so reconnect and verify again once.
    if !channel.is_usable().await {
        info!("NEAR AI connection closed during verification; verifying a new connection");
        let (fresh, fresh_report, address) =
            open_and_attest(model, progress).await.map_err(|e| verification(progress, e))?;
        channel = fresh;
        report = fresh_report;
        signing_address = address;
    }
    let failed = |report: &TeeReport, error: String, signature_failed: bool| CloudError::Request {
        report: Box::new(report.clone()),
        error,
        signature_failed,
    };

    let response = channel
        .send(Method::POST, "/v1/chat/completions", Some(api_key), Some(request_body.clone()), CHAT_LIMIT, CHAT_TIMEOUT)
        .await
        .map_err(|e| failed(&report, e, false))?;
    if KEY_REJECTED_STATUSES.contains(&response.status) {
        return Err(failed(&report, format!("{KEY_REJECTED} (HTTP {})", response.status), false));
    }
    if response.status != 200 {
        // The body is the model host's, and could quote the prompt back, so
        // only the status is reported or logged.
        return Err(failed(&report, format!("The private cloud model returned HTTP {}", response.status), false));
    }
    let chat_id = serde_json::from_slice::<serde_json::Value>(&response.body)
        .ok()
        .and_then(|v| v["id"].as_str().map(str::to_string))
        .ok_or_else(|| failed(&report, "NEAR AI response has no id".into(), true))?;

    let path = format!(
        "/v1/signature/{}?model={}&signing_algo=ecdsa",
        urlencoding::encode(&chat_id),
        urlencoding::encode(model)
    );
    let mut attempt = 0;
    let signature: ChatSignature = loop {
        attempt += 1;
        let reply = channel
            .send(Method::GET, &path, Some(api_key), None, ATTESTATION_LIMIT, ATTESTATION_TIMEOUT)
            .await
            .map_err(|e| failed(&report, e, true))?;
        if reply.status == 200 {
            break serde_json::from_slice(&reply.body)
                .map_err(|e| failed(&report, format!("Unexpected response signature: {e}"), true))?;
        }
        if attempt >= SIGNATURE_ATTEMPTS {
            return Err(failed(
                &report,
                format!("NEAR AI did not provide a response signature (HTTP {})", reply.status),
                true,
            ));
        }
        tokio::time::sleep(Duration::from_secs(1)).await;
    };
    evidence::check_chat_signature(&signature, model, &request_body, &response.body, &signing_address)
        .map_err(|e| failed(&report, e, true))?;
    Ok((response.body.to_vec(), report))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A full-size chunk, to check the channel and the enclave take a request
    /// as large as chunking will actually send. Opt-in: it bills real tokens.
    #[tokio::test]
    #[ignore]
    async fn nearai_live_large_request() {
        let Some(key) = api_key_for_tests() else {
            panic!("this test needs a NEAR AI key in ~/.nearai-key");
        };
        let model = std::env::var("NEARAI_MODEL").unwrap_or_else(|_| "z-ai/glm-5.3-flash".into());
        let chunk_tokens = chunk_tokens_for(&model).await;
        // rough_token_count counts 0.35 tokens per character.
        let filler = "The meeting continued with a further point of discussion. ".repeat(chunk_tokens * 3 / 58);
        let body = serde_json::json!({
            "model": model,
            "messages": [{"role": "user", "content": format!("{filler}\n\nReply with the word ok.")}],
            "max_tokens": 64,
        });
        let request = serde_json::to_vec(&body).unwrap();
        println!("chunk budget {chunk_tokens} tokens, request {} bytes", request.len());
        let started = std::time::Instant::now();
        let mut progress = Progress { stage: Stage::Connect, notify: &ignore_progress, unread: Vec::new() };
        let (reply, _) = chat_completion(&model, &key, request, &mut progress).await.unwrap();
        let reply: serde_json::Value = serde_json::from_slice(&reply).unwrap();
        println!("usage {} in {:?}", reply["usage"], started.elapsed());
    }

    /// A key kept outside the repo, so it is never committed or pasted.
    fn api_key_for_tests() -> Option<String> {
        if let Ok(key) = std::env::var("NEARAI_API_KEY") {
            return Some(key);
        }
        std::env::var("HOME")
            .map(|home| std::path::PathBuf::from(home).join(".nearai-key"))
            .ok()
            .and_then(|path| std::fs::read_to_string(path).ok())
            .map(|key| key.trim().to_string())
            .filter(|key| !key.is_empty())
    }

    /// Live check against NEAR AI, Intel and NVIDIA. Run with
    /// `NEARAI_MODEL=<model id> cargo test nearai_live -- --ignored --nocapture`.
    #[tokio::test]
    #[ignore]
    async fn nearai_live_verification() {
        for m in list_models().await.unwrap() {
            println!("{:32} {:?} ctx={:?} in={:?} out={:?}", m.id, m.suggestion.map(|s| s.label), m.context_length, m.input_price, m.output_price);
        }
        let model = std::env::var("NEARAI_MODEL").unwrap_or_else(|_| "z-ai/glm-5.3-flash".into());
        let started = std::time::Instant::now();
        let report = verify_model(&model).await.unwrap();
        println!("{report:#?}\nfirst verification: {:?}", started.elapsed());
        let started = std::time::Instant::now();
        verify_model(&model).await.unwrap();
        println!("second verification (cached Intel and NVIDIA data): {:?}", started.elapsed());
        if let Some(key) = api_key_for_tests() {
            let body = serde_json::json!({
                "model": model,
                "messages": [{"role": "user", "content": "Reply with the word ok."}],
                "max_tokens": 64,
            });
            let mut progress = Progress { stage: Stage::Connect, notify: &ignore_progress, unread: Vec::new() };
            let (reply, _) = chat_completion(&model, &key, serde_json::to_vec(&body).unwrap(), &mut progress).await.unwrap();
            println!("{}", String::from_utf8_lossy(&reply));
        }
    }

    /// `NEARAI_API_KEY=sk-… cargo test --lib nearai_live_key_check -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn nearai_live_key_check() {
        assert_eq!(key_accepted("sk-00000000000000000000000000000000").await, Ok(false));
        let key = api_key_for_tests().expect("this test needs a NEAR AI key in ~/.nearai-key");
        assert_eq!(key_accepted(&key).await, Ok(true));
    }

    #[test]
    fn only_an_incomplete_request_accepts_a_key_and_only_a_rejection_refuses_it() {
        assert_eq!(key_check_result(400), Ok(true));
        for status in KEY_REJECTED_STATUSES {
            assert_eq!(key_check_result(status), Ok(false));
        }
        for status in [200, 301, 404, 429, 500, 503] {
            assert!(key_check_result(status).is_err(), "{status}");
        }
    }

    #[test]
    fn model_list_keeps_attested_text_models_and_puts_suggestions_first() {
        let hosts = vec![
            ("Qwen/Qwen3.8-27B".to_string(), "qwen3-8-27b.completions.near.ai".to_string()),
            ("z-ai/glm-5.3-flash".to_string(), "glm-5-3-flash.completions.near.ai".to_string()),
            ("zai-org/GLM-5.1-FP8".to_string(), "glm-5-1.completions.near.ai".to_string()),
            ("acme/big-text".to_string(), "big-text.completions.near.ai".to_string()),
            ("acme/image-gen".to_string(), "image-gen.completions.near.ai".to_string()),
            ("acme/short".to_string(), "short.completions.near.ai".to_string()),
            ("acme/unattested".to_string(), "unattested.completions.near.ai".to_string()),
        ];
        let text = |ctx: u64, attested: bool| {
            serde_json::json!({
                "attestationSupported": attested,
                "contextLength": ctx,
                "architecture": {"inputModalities": ["text"], "outputModalities": ["text"]},
            })
        };
        let catalogue: Catalogue = serde_json::from_value(serde_json::json!({"models": [
            {"modelId": "acme/big-text", "metadata": text(200_000, true)},
            {"modelId": "Qwen/Qwen3.8-27B", "metadata": text(262_144, true),
             "inputCostPerToken": {"amount": 440, "scale": 9, "currency": "USD"}},
            {"modelId": "z-ai/glm-5.3-flash", "metadata": text(1_048_576, true)},
            {"modelId": "acme/image-gen", "metadata": {"attestationSupported": true, "contextLength": 128000,
             "architecture": {"inputModalities": ["text"], "outputModalities": ["image"]}}},
            {"modelId": "acme/short", "metadata": text(16_384, true)},
            {"modelId": "acme/unattested", "metadata": text(200_000, false)},
            {"modelId": "acme/not-hosted", "metadata": text(200_000, true)},
        ]}))
        .unwrap();

        let models = build_model_list(hosts, catalogue);
        let ids: Vec<&str> = models.iter().map(|m| m.id.as_str()).collect();
        assert_eq!(ids, ["z-ai/glm-5.3-flash", "Qwen/Qwen3.8-27B", "acme/big-text"]);
        assert_eq!(models[0].suggestion.as_ref().unwrap().label, "Recommended");
        assert!(models[2].suggestion.is_none());
        assert!((models[1].input_price.unwrap() - 0.44).abs() < 1e-9);
    }

    fn service(weights: &str, revision: Option<&str>, image: &str) -> evidence::ModelService {
        evidence::ModelService {
            service: format!("server-{weights}-{revision:?}-{image}"),
            image: image.to_string(),
            weights: weights.to_string(),
            revision: revision.map(str::to_string),
        }
    }

    fn deployment(commit: &str) -> evidence::Deployment {
        evidence::Deployment {
            commit: commit.to_string(),
            path: "prod/models.yaml".into(),
            file_sha256: "1".repeat(64),
        }
    }

    #[test]
    fn replicas_on_different_engine_builds_are_reported_together() {
        let found = vec![
            (deployment("bbb"), service("org/M", Some("beefcafe"), "reg/b@sha256:2")),
            (deployment("aaa"), service("org/M", Some("beefcafe"), "reg/a@sha256:1")),
        ];
        let source = agree_on_source(found, None, "org/M").unwrap().unwrap();
        assert_eq!(source.images, vec!["reg/a@sha256:1".to_string(), "reg/b@sha256:2".to_string()]);
        assert_eq!(source.commit, "aaa", "the answer does not depend on fetch order");
    }

    #[test]
    fn services_serving_different_weights_are_refused() {
        let differing_revision = vec![
            (deployment("aaa"), service("org/M", Some("beefcafe"), "reg/a@sha256:1")),
            (deployment("aaa"), service("org/M", Some("deadbeef"), "reg/a@sha256:1")),
        ];
        let error = agree_on_source(differing_revision, None, "org/M").unwrap_err();
        assert!(error.contains("beefcafe") && error.contains("deadbeef"), "{error}");

        let differing_weights = vec![
            (deployment("aaa"), service("org/M", None, "reg/a@sha256:1")),
            (deployment("aaa"), service("org/Other", None, "reg/a@sha256:1")),
        ];
        let error = agree_on_source(differing_weights, None, "org/M").unwrap_err();
        assert!(error.contains("org/Other"), "{error}");
    }

    #[test]
    fn a_deployment_we_could_not_read_leaves_the_answer_unknown() {
        // Something unseen might also be serving this model.
        let found = vec![(deployment("aaa"), service("org/M", Some("beefcafe"), "reg/a@sha256:1"))];
        assert!(agree_on_source(found, Some("GitHub is unreachable".into()), "org/M").unwrap().is_none());
        assert!(agree_on_source(Vec::new(), Some("GitHub is unreachable".into()), "org/M").unwrap().is_none());
        // With everything read and nothing serving it, the request stops.
        assert!(agree_on_source(Vec::new(), None, "org/M").is_err());
    }

    #[test]
    fn chunk_size_leaves_room_for_instructions_and_notes() {
        assert_eq!(chunk_tokens(65_536), 36_428);
        assert_eq!(chunk_tokens(262_144), 100_000);
        assert_eq!(chunk_tokens(1_048_576), 100_000);
        assert_eq!(chunk_tokens(16_000), 4_000);
    }

    #[test]
    fn deploy_log_quote_is_from_the_same_enclave() {
        let report: AttestationReport =
            serde_json::from_str(include_str!("testdata/attestation.json")).unwrap();
        let main = dcap_qvl::quote::Quote::parse(&hex::decode(&report.intel_quote).unwrap()).unwrap();
        let cm_attestation = report.compose_manager_attestation.as_ref().unwrap();
        let cm = dcap_qvl::quote::Quote::parse(&hex::decode(&cm_attestation.quote).unwrap()).unwrap();
        assert!(same_enclave(td_report(&main.report).unwrap(), td_report(&cm.report).unwrap()));
    }
}
