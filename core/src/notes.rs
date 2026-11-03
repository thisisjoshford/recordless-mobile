//! Notes from the private cloud: a NEAR AI model in a TEE, reached only through
//! `nearai::chat_completion`, which attests the host on the same TLS
//! connection before the prompt is sent and checks the response signature
//! after. There is no local notes model and no other provider.
//!
//! The transcript arrives here already scrubbed (see `Session::generate_notes`)
//! and never leaves the core except inside an attested request. Swift receives
//! the notes, token counts, timings and what was verified.
//!
//! The chunk -> combine -> final-report flow and the output cleaning are ported
//! from desktop `summary/processor.rs` (`generate_meeting_summary`,
//! `clean_llm_markdown_detailed`, `chunk_text`). Translation, English
//! normalisation and the summary cache are not ported: iOS writes English notes.

use std::sync::{Arc, LazyLock, Mutex};

use regex::Regex;
use serde::Deserialize;
use zeroize::Zeroizing;

use crate::nearai::{self, CloudError, NearAiModel, Progress, Stage, TeeReport};
use crate::prompt::{self, build_notes_prompt, privacy_rules};
use crate::redact::ScrubOptions;

// ---- FFI records -----------------------------------------------------------

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct NotesResult {
    /// Generated notes (allowed to cross; the transcript is not).
    pub markdown: String,
    pub model_id: String,
    pub verification: VerificationReport,
    /// Summed over every attested request this generation made.
    pub prompt_tokens: u32,
    pub generated_tokens: u32,
    /// Attested requests made (1, or chunks + combine + final for long meetings).
    pub requests: u32,
    pub elapsed_ms: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum CheckOutcome {
    Passed,
    /// The check could not be read (for example GitHub unreachable, or weights
    /// without a pinned revision). Neither passed nor failed; shown as such.
    Unread,
    Failed,
    /// An earlier check failed, so this one never ran.
    NotRun,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VerificationCheck {
    /// Stable id: connect, model, hardware, binding, software, deploy, weights, gpu, signature.
    pub id: String,
    pub label: String,
    pub outcome: CheckOutcome,
    /// What was seen (passed), or why it failed / was unread.
    pub detail: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VerificationReport {
    pub model_id: String,
    /// The `*.completions.near.ai` host, when one was reached.
    pub host: Option<String>,
    /// No check failed and the response signature passed. Unread checks do not
    /// make this false; they are listed as unread.
    pub passed: bool,
    pub checks: Vec<VerificationCheck>,
    /// Intel TDX platform status (`UpToDate`, `SWHardeningNeeded`, `OutOfDate`).
    pub tcb_status: Option<String>,
    /// Requests whose attestation and signature this report covers.
    pub attested_requests: u32,
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct CloudModel {
    pub id: String,
    pub display_name: String,
    pub description: Option<String>,
    pub context_length: Option<u64>,
    pub max_output_tokens: Option<u64>,
    /// USD per million tokens.
    pub input_price: Option<f64>,
    pub output_price: Option<f64>,
    /// "Recommended", "Fastest and cheapest", ...
    pub suggestion_label: Option<String>,
    pub suggestion_reason: Option<String>,
    /// The model used when `generate_notes` is given no model id.
    pub recommended: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct NotesStatus {
    pub running: bool,
    /// Readable label of the step in progress.
    pub step: Option<String>,
    /// 1-based index of the attested request in progress, and the total planned.
    pub request: u32,
    pub requests: u32,
    /// What the latest finished or failed request verified, kept after failure.
    pub last_verification: Option<VerificationReport>,
}

// ---- verification report ---------------------------------------------------

fn stage_id(stage: Stage) -> &'static str {
    match stage {
        Stage::Connect => "connect",
        Stage::Model => "model",
        Stage::Hardware => "hardware",
        Stage::Binding => "binding",
        Stage::Software => "software",
        Stage::Deploy => "deploy",
        Stage::Weights => "weights",
        Stage::Gpu => "gpu",
    }
}

pub(crate) fn stage_label(stage: Stage) -> &'static str {
    match stage {
        Stage::Connect => "Connected to a NEAR AI TEE host",
        Stage::Model => "Host is serving the requested model",
        Stage::Hardware => "Genuine Intel TDX hardware (non-debug, accepted TCB)",
        Stage::Binding => "Quote binds this request, this TLS connection and the signing key",
        Stage::Software => "Measured software matches the manifest and boot log",
        Stage::Deploy => "NEAR deploy-manager log from the same enclave",
        Stage::Weights => "Serving image and model weights pinned",
        Stage::Gpu => "NVIDIA verified the GPUs for this request",
    }
}

const SIGNATURE_ID: &str = "signature";
const SIGNATURE_LABEL: &str = "Response signed by the attested key";

fn short(hex: &str) -> String {
    hex.chars().take(16).collect()
}

fn passed_detail(stage: Stage, report: &TeeReport) -> Option<String> {
    Some(match stage {
        Stage::Connect => format!("{} (WebPKI TLS)", report.host),
        Stage::Model => report.model.clone(),
        Stage::Hardware if report.advisory_ids.is_empty() => format!("TCB {}", report.tcb_status),
        Stage::Hardware => format!("TCB {} (advisories: {})", report.tcb_status, report.advisory_ids.join(", ")),
        Stage::Binding => format!("TLS key {}…, signer {}", short(&report.tls_key_sha256), report.signing_address),
        Stage::Software => format!(
            "Manifest {}…: private logs, attested key service, images pinned by digest",
            short(&report.compose_hash)
        ),
        Stage::Deploy => match report.deploy_actions {
            Some(n) => format!("{n} logged actions"),
            None => "No deploy log on this host".into(),
        },
        Stage::Weights => match &report.model_source {
            Some(source) => format!(
                "{} at {} via {} ({} @ {})",
                source.weights,
                source.revision.as_deref().unwrap_or("no fixed revision"),
                source.images.join(", "),
                source.compose_file,
                short(&source.commit)
            ),
            None => "The deployment could not be read".into(),
        },
        Stage::Gpu => format!("{} GPU(s)", report.gpu_count),
    })
}

fn unread_detail(stage: Stage, report: &TeeReport) -> String {
    match stage {
        Stage::Deploy => "The deploy manager running now is not one the measured manifest names".into(),
        Stage::Weights => match &report.model_source {
            Some(source) if source.revision.is_none() => {
                format!("{} has no pinned revision, so the weights can change", source.weights)
            }
            _ => "The deployment could not be read in full".into(),
        },
        _ => "Could not be read".into(),
    }
}

/// Every check passed or unread, then the signature outcome.
fn report_for_success(report: &TeeReport, signature: CheckOutcome, signature_detail: Option<String>) -> Vec<VerificationCheck> {
    let mut checks: Vec<VerificationCheck> = Stage::ALL
        .iter()
        .map(|&stage| {
            let unread = report.skipped_stages.contains(&stage);
            VerificationCheck {
                id: stage_id(stage).into(),
                label: stage_label(stage).into(),
                outcome: if unread { CheckOutcome::Unread } else { CheckOutcome::Passed },
                detail: if unread { Some(unread_detail(stage, report)) } else { passed_detail(stage, report) },
            }
        })
        .collect();
    checks.push(VerificationCheck {
        id: SIGNATURE_ID.into(),
        label: SIGNATURE_LABEL.into(),
        outcome: signature,
        detail: signature_detail,
    });
    checks
}

/// Checks before `failed` passed (or were unread), `failed` failed, the rest never ran.
fn report_for_failure(failed: Stage, unread: &[Stage], error: &str) -> Vec<VerificationCheck> {
    let failed_at = Stage::ALL.iter().position(|s| *s == failed).unwrap_or(0);
    let mut checks: Vec<VerificationCheck> = Stage::ALL
        .iter()
        .enumerate()
        .map(|(i, &stage)| {
            let (outcome, detail) = match i.cmp(&failed_at) {
                std::cmp::Ordering::Less if unread.contains(&stage) => (CheckOutcome::Unread, None),
                std::cmp::Ordering::Less => (CheckOutcome::Passed, None),
                std::cmp::Ordering::Equal => (CheckOutcome::Failed, Some(error.to_string())),
                std::cmp::Ordering::Greater => (CheckOutcome::NotRun, None),
            };
            VerificationCheck { id: stage_id(stage).into(), label: stage_label(stage).into(), outcome, detail }
        })
        .collect();
    checks.push(VerificationCheck {
        id: SIGNATURE_ID.into(),
        label: SIGNATURE_LABEL.into(),
        outcome: CheckOutcome::NotRun,
        detail: None,
    });
    checks
}

fn verification_report(
    model: &str,
    report: Option<&TeeReport>,
    checks: Vec<VerificationCheck>,
    attested_requests: u32,
) -> VerificationReport {
    let passed = checks.iter().all(|c| matches!(c.outcome, CheckOutcome::Passed | CheckOutcome::Unread))
        && checks.iter().any(|c| c.id == SIGNATURE_ID && c.outcome == CheckOutcome::Passed);
    VerificationReport {
        model_id: model.to_string(),
        host: report.map(|r| r.host.clone()),
        passed,
        checks,
        tcb_status: report.map(|r| r.tcb_status.clone()),
        attested_requests,
    }
}

// ---- model list --------------------------------------------------------------

/// The model used when none is named: NEAR AI's catalogue entry for our
/// "Recommended" suggestion if it is listed, else the first listed model.
fn recommended(models: &[NearAiModel]) -> Option<&NearAiModel> {
    models
        .iter()
        .find(|m| m.suggestion.as_ref().is_some_and(|s| s.label == "Recommended"))
        .or_else(|| models.first())
}

pub(crate) fn cloud_models(models: &[NearAiModel]) -> Vec<CloudModel> {
    let recommended_id = recommended(models).map(|m| m.id.clone());
    models
        .iter()
        .map(|m| CloudModel {
            id: m.id.clone(),
            display_name: m.display_name.clone(),
            description: m.description.clone(),
            context_length: m.context_length,
            max_output_tokens: m.max_output_tokens,
            input_price: m.input_price,
            output_price: m.output_price,
            suggestion_label: m.suggestion.as_ref().map(|s| s.label.to_string()),
            suggestion_reason: m.suggestion.as_ref().map(|s| s.reason.to_string()),
            recommended: recommended_id.as_deref() == Some(m.id.as_str()),
        })
        .collect()
}

// ---- output cleaning (desktop processor.rs) ---------------------------------

static THINK_ENVELOPE_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)<think(?:ing)?(?:\s+[^>]*)?>.*?</think(?:ing)?\s*>").unwrap());
static THINK_MARKER_REGEX: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"(?is)</?think(?:ing)?(?:\s+[^>]*)?>").unwrap());

#[derive(Debug, Clone, PartialEq, Eq)]
struct CleanedLlmMarkdown {
    markdown: String,
    reasoning_stripped: bool,
}

fn clean_llm_markdown_detailed(raw: &str) -> CleanedLlmMarkdown {
    let visible = THINK_ENVELOPE_REGEX.replace_all(raw, "");
    let reasoning_stripped = visible.as_ref() != raw;
    let trimmed = visible.trim();
    const PREFIXES: &[&str] = &["```markdown\n", "```\n", "```markdown\r\n", "```\r\n"];
    const SUFFIX: &str = "```";
    let markdown = PREFIXES
        .iter()
        .find_map(|prefix| {
            (trimmed.starts_with(prefix) && trimmed.ends_with(SUFFIX))
                .then(|| trimmed[prefix.len()..trimmed.len() - SUFFIX.len()].trim())
        })
        .unwrap_or(trimmed)
        .to_string();
    CleanedLlmMarkdown { markdown, reasoning_stripped }
}

fn require_visible_markdown(stage: &str, cleaned: &CleanedLlmMarkdown) -> Result<(), String> {
    if THINK_MARKER_REGEX.is_match(&cleaned.markdown) {
        Err(format!("{stage} contained an unterminated reasoning marker"))
    } else if cleaned.markdown.is_empty() {
        Err(format!("{stage} returned no visible summary content after reasoning removal"))
    } else {
        Ok(())
    }
}

/// Rough token count estimation using character count (desktop).
fn rough_token_count(s: &str) -> usize {
    (s.chars().count() as f64 * 0.35).ceil() as usize
}

/// Overlapping, word-boundary chunks of roughly `chunk_size_tokens` (desktop `chunk_text`).
fn chunk_text(text: &str, chunk_size_tokens: usize, overlap_tokens: usize) -> Vec<Zeroizing<String>> {
    if text.is_empty() || chunk_size_tokens == 0 {
        return vec![];
    }
    let chars_per_token = 1.0 / 0.35;
    let chunk_size_chars = (chunk_size_tokens as f64 * chars_per_token).ceil() as usize;
    let overlap_chars = (overlap_tokens as f64 * chars_per_token).ceil() as usize;
    let chars: Vec<char> = text.chars().collect();
    let total_chars = chars.len();
    if total_chars <= chunk_size_chars {
        return vec![Zeroizing::new(text.to_string())];
    }
    let mut chunks = Vec::new();
    let mut start_char = 0;
    while start_char < total_chars {
        let end_char = (start_char + chunk_size_chars).min(total_chars);
        let mut emitted_end_char = end_char;
        let start_byte: usize = chars[..start_char].iter().map(|c| c.len_utf8()).sum();
        let mut end_byte: usize = chars[..end_char].iter().map(|c| c.len_utf8()).sum();
        if end_char < total_chars {
            let slice = &text[start_byte..end_byte];
            let sentence_boundary = slice.rfind(". ").map(|index| index + 2);
            let word_boundary = slice.rfind(' ').map(|index| index + 1);
            let boundary = sentence_boundary
                .filter(|end| slice[..*end].chars().count() > overlap_chars)
                .or_else(|| word_boundary.filter(|end| slice[..*end].chars().count() > overlap_chars));
            if let Some(boundary) = boundary {
                end_byte = start_byte + boundary;
                emitted_end_char = start_char + slice[..boundary].chars().count();
            }
        }
        chunks.push(Zeroizing::new(text[start_byte..end_byte].to_string()));
        if emitted_end_char >= total_chars {
            break;
        }
        start_char = emitted_end_char.saturating_sub(overlap_chars).max(start_char + 1);
    }
    chunks
}

const MAX_CHUNK_ATTEMPTS: usize = 2;

/// A timed-out chunk isn't retried: a second try would likely wait just as long.
fn should_retry_chunk_failure(attempt: usize, error: &str) -> bool {
    attempt < MAX_CHUNK_ATTEMPTS && !error.contains("timed out")
}

#[derive(Deserialize)]
struct ChatResponse {
    choices: Vec<Choice>,
    #[serde(default)]
    usage: Option<Usage>,
}

#[derive(Deserialize)]
struct Choice {
    message: MessageContent,
}

#[derive(Deserialize)]
struct MessageContent {
    #[serde(default)]
    content: Option<String>,
}

#[derive(Deserialize, Default)]
struct Usage {
    #[serde(default)]
    prompt_tokens: u64,
    #[serde(default)]
    completion_tokens: u64,
}

// ---- the run ------------------------------------------------------------------

/// Live state shared with `Session::notes_status`.
#[derive(Default)]
pub(crate) struct LiveStatus {
    pub step: Option<String>,
    pub request: u32,
    pub requests: u32,
    pub last_verification: Option<VerificationReport>,
}

/// A failed run, as the session reports it.
pub(crate) enum RunError {
    /// Verification failed before anything but attestation evidence was sent.
    Attestation(String),
    /// Anything else (network, key, credit, model output, signature).
    Cloud(String),
}

pub(crate) struct Run<'a> {
    pub api_key: &'a str,
    pub model_id: Option<String>,
    pub scrub: ScrubOptions,
    pub status: Arc<Mutex<LiveStatus>>,
}

pub(crate) struct Totals {
    prompt_tokens: u64,
    generated_tokens: u64,
    requests: u32,
    last_report: Option<TeeReport>,
}

impl Run<'_> {
    fn set_step(&self, step: impl Into<String>) {
        if let Ok(mut s) = self.status.lock() {
            s.step = Some(step.into());
        }
    }

    fn set_verification(&self, report: VerificationReport) {
        if let Ok(mut s) = self.status.lock() {
            s.last_verification = Some(report);
        }
    }

    /// One attested request; records what was verified either way.
    async fn complete(
        &self,
        model: &str,
        system: &str,
        user: &str,
        totals: &mut Totals,
        stage_label_for: &str,
    ) -> Result<CleanedLlmMarkdown, RunError> {
        totals.requests += 1;
        if let Ok(mut s) = self.status.lock() {
            s.request = totals.requests;
        }
        let body = serde_json::json!({
            "model": model,
            "messages": [
                {"role": "system", "content": system},
                {"role": "user", "content": user},
            ],
        });
        let body = Zeroizing::new(serde_json::to_vec(&body).map_err(|e| RunError::Cloud(format!("Failed to encode request: {e}")))?);
        let status = Arc::clone(&self.status);
        let notify = move |stage: Stage| {
            if let Ok(mut s) = status.lock() {
                s.step = Some(stage_label(stage).to_string());
            }
        };
        let mut progress = Progress { stage: Stage::Connect, notify: &notify, unread: Vec::new() };
        let outcome = nearai::chat_completion(model, self.api_key, body.to_vec(), &mut progress).await;
        drop(body);
        let (raw, report) = match outcome {
            Ok(ok) => ok,
            Err(CloudError::Verification { stage, error }) => {
                let checks = report_for_failure(stage, &progress.unread, &error);
                self.set_verification(verification_report(model, None, checks, totals.requests));
                return Err(RunError::Attestation(error));
            }
            Err(CloudError::Request { report, error, signature_failed }) => {
                let (outcome, detail) = if signature_failed {
                    (CheckOutcome::Failed, Some(error.clone()))
                } else {
                    (CheckOutcome::NotRun, None)
                };
                let checks = report_for_success(&report, outcome, detail);
                self.set_verification(verification_report(model, Some(&report), checks, totals.requests));
                return Err(RunError::Cloud(error));
            }
        };
        let raw = Zeroizing::new(raw);
        let response: ChatResponse = serde_json::from_slice(&raw)
            .map_err(|e| RunError::Cloud(format!("Failed to parse the private cloud response: {e}")))?;
        let usage = response.usage.unwrap_or_default();
        totals.prompt_tokens += usage.prompt_tokens;
        totals.generated_tokens += usage.completion_tokens;
        let content = Zeroizing::new(
            response
                .choices
                .into_iter()
                .next()
                .and_then(|c| c.message.content)
                .ok_or_else(|| RunError::Cloud("No content in the private cloud response".into()))?,
        );
        let cleaned = clean_llm_markdown_detailed(content.trim());
        totals.last_report = Some(report);
        require_visible_markdown(stage_label_for, &cleaned).map_err(RunError::Cloud)?;
        Ok(cleaned)
    }

    /// Generate notes from an already scrubbed transcript.
    pub async fn run(&self, scrubbed_transcript: &str) -> Result<(String, String, Totals), RunError> {
        self.set_step("Listing private cloud models");
        let listed = nearai::list_models().await;
        let model = match (&self.model_id, &listed) {
            (Some(id), _) => id.clone(),
            (None, Ok(models)) => recommended(models)
                .map(|m| m.id.clone())
                .ok_or_else(|| RunError::Cloud("NEAR AI lists no private cloud model for notes".into()))?,
            (None, Err(error)) => return Err(RunError::Cloud(error.clone())),
        };
        // Same budget as desktop `chunk_tokens_for`.
        let threshold = listed
            .ok()
            .and_then(|models| models.into_iter().find(|m| m.id == model).and_then(|m| m.context_length))
            .map_or(nearai::FALLBACK_CHUNK_TOKENS, nearai::chunk_tokens);

        let rules = privacy_rules(&self.scrub);
        let mut totals = Totals { prompt_tokens: 0, generated_tokens: 0, requests: 0, last_report: None };

        let content: Zeroizing<String> = if rough_token_count(scrubbed_transcript) >= threshold {
            let chunks = chunk_text(scrubbed_transcript, threshold - 300, 100);
            let n = chunks.len();
            if let Ok(mut s) = self.status.lock() {
                s.requests = n as u32 + u32::from(n > 1) + 1;
            }
            let mut summaries: Vec<Zeroizing<String>> = Vec::with_capacity(n);
            for (index, chunk) in chunks.iter().enumerate() {
                let user = prompt::build_chunk_summary_user_prompt(chunk, &rules);
                let mut attempt = 0;
                loop {
                    attempt += 1;
                    match self.complete(&model, prompt::CHUNK_SYSTEM_PROMPT, &user, &mut totals, "Summary chunk").await {
                        Ok(cleaned) => {
                            summaries.push(Zeroizing::new(cleaned.markdown));
                            break;
                        }
                        // A failed attestation is never retried around.
                        Err(RunError::Attestation(e)) => return Err(RunError::Attestation(e)),
                        Err(RunError::Cloud(e)) if should_retry_chunk_failure(attempt, &e) && !e.contains(nearai::KEY_REJECTED) => {}
                        Err(RunError::Cloud(e)) => {
                            return Err(RunError::Cloud(if e.contains(nearai::KEY_REJECTED) {
                                e
                            } else {
                                format!(
                                    "Notes could not complete because transcript section {} of {n} failed after {attempt} attempts: {e}. Please retry.",
                                    index + 1
                                )
                            }))
                        }
                    }
                }
            }
            if summaries.len() == 1 {
                summaries.remove(0)
            } else {
                let joined = Zeroizing::new(summaries.iter().map(|s| s.as_str()).collect::<Vec<_>>().join("\n---\n"));
                drop(summaries);
                let user = prompt::build_combine_summary_user_prompt(&joined, &rules);
                Zeroizing::new(
                    self.complete(&model, prompt::COMBINE_SYSTEM_PROMPT, &user, &mut totals, "Combined summary")
                        .await?
                        .markdown,
                )
            }
        } else {
            if let Ok(mut s) = self.status.lock() {
                s.requests = 1;
            }
            Zeroizing::new(scrubbed_transcript.to_string())
        };

        let final_prompt = build_notes_prompt(&content, &self.scrub);
        drop(content);
        let cleaned = self
            .complete(&model, &final_prompt.system, &final_prompt.user, &mut totals, "Final summary")
            .await?;
        let report = totals.last_report.clone().expect("a request succeeded");
        let verification = verification_report(
            &model,
            Some(&report),
            report_for_success(&report, CheckOutcome::Passed, Some(short(&report.signing_address))),
            totals.requests,
        );
        self.set_verification(verification);
        Ok((cleaned.markdown, model, totals))
    }
}

pub(crate) fn into_result(markdown: String, model: String, totals: Totals, status: &LiveStatus, elapsed_ms: u64) -> NotesResult {
    let verification = status
        .last_verification
        .clone()
        .expect("a successful run records its verification");
    NotesResult {
        markdown,
        model_id: model,
        verification,
        prompt_tokens: totals.prompt_tokens.min(u32::MAX as u64) as u32,
        generated_tokens: totals.generated_tokens.min(u32::MAX as u64) as u32,
        requests: totals.requests,
        elapsed_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_text_preserves_content_after_early_sentence_boundary() {
        let marker = "LOST_MARKER";
        let text = format!("Intro. {marker} trailing content ensures chunking");
        let chunks = chunk_text(&text, 10, 1);
        assert!(chunks.iter().any(|chunk| chunk.contains(marker)));
    }

    #[test]
    fn chunk_text_keeps_unicode_boundaries() {
        let chunks: Vec<String> = chunk_text("é ab", 1, 0).iter().map(|c| c.to_string()).collect();
        assert_eq!(chunks, vec!["é ", "ab"]);
    }

    #[test]
    fn chunk_text_progresses_when_overlap_matches_window() {
        let chunks: Vec<String> = chunk_text("abcd", 1, 1).iter().map(|c| c.to_string()).collect();
        assert_eq!(chunks, vec!["abc", "bcd"]);
    }

    #[test]
    fn chunk_retries_once_unless_timed_out() {
        assert!(should_retry_chunk_failure(1, "HTTP 502"));
        assert!(!should_retry_chunk_failure(2, "HTTP 502"));
        assert!(!should_retry_chunk_failure(1, "Request to glm-5-3-flash.completions.near.ai timed out"));
    }

    #[test]
    fn cleaner_removes_closed_reasoning_envelopes_everywhere() {
        let cleaned = clean_llm_markdown_detailed(
            "Intro\n<think>private</think>\n# Meeting\nHello\n<thinking>also private</thinking>\nTail",
        );
        assert!(cleaned.reasoning_stripped);
        assert!(!cleaned.markdown.contains("<think"));
        assert!(cleaned.markdown.contains("Intro") && cleaned.markdown.contains("Tail"));
        let fenced = clean_llm_markdown_detailed("```\n<think>private</think>\nvisible\n```");
        assert_eq!(fenced.markdown, "visible");
        let literal = clean_llm_markdown_detailed("<thinker>Visible</thinker>");
        assert!(!literal.reasoning_stripped);
        assert_eq!(literal.markdown, "<thinker>Visible</thinker>");
    }

    #[test]
    fn cleaner_rejects_unterminated_reasoning_markers_and_empty_output() {
        for raw in ["Visible\n<think>private", "Visible\n</thinking>"] {
            assert_eq!(
                require_visible_markdown("Final summary", &clean_llm_markdown_detailed(raw)),
                Err("Final summary contained an unterminated reasoning marker".to_string())
            );
        }
        for raw in ["<think>private</think>", "```\n```", "```markdown\r\n```"] {
            assert!(require_visible_markdown("Final summary", &clean_llm_markdown_detailed(raw)).is_err(), "{raw:?}");
        }
    }

    fn tee_report(skipped: Vec<Stage>) -> TeeReport {
        TeeReport {
            host: "glm.completions.near.ai".into(),
            model: "org/M".into(),
            signing_address: "0xabc".into(),
            tcb_status: "OutOfDate".into(),
            advisory_ids: vec!["INTEL-SA-1".into()],
            gpu_count: 8,
            compose_hash: "c".repeat(64),
            deploy_actions: Some(3),
            tls_key_sha256: "d".repeat(64),
            model_source: None,
            skipped_stages: skipped,
        }
    }

    #[test]
    fn a_report_shows_unread_checks_as_unread_and_still_passes() {
        let report = tee_report(vec![Stage::Weights]);
        let checks = report_for_success(&report, CheckOutcome::Passed, None);
        assert_eq!(checks.len(), 9);
        let weights = checks.iter().find(|c| c.id == "weights").unwrap();
        assert_eq!(weights.outcome, CheckOutcome::Unread);
        assert!(checks.iter().filter(|c| c.id != "weights").all(|c| c.outcome == CheckOutcome::Passed));
        let v = verification_report("org/M", Some(&report), checks, 1);
        assert!(v.passed);
        assert_eq!(v.tcb_status.as_deref(), Some("OutOfDate"));
    }

    #[test]
    fn a_bad_signature_fails_the_report() {
        let report = tee_report(vec![]);
        let checks = report_for_success(&report, CheckOutcome::Failed, Some("not signed".into()));
        assert!(!verification_report("org/M", Some(&report), checks, 1).passed);
        let unsent = report_for_success(&report, CheckOutcome::NotRun, None);
        assert!(!verification_report("org/M", Some(&report), unsent, 1).passed, "no signature, no pass");
    }

    #[test]
    fn a_failed_stage_is_marked_and_later_ones_never_ran() {
        let checks = report_for_failure(Stage::Software, &[Stage::Deploy], "manifest mismatch");
        let outcome = |id: &str| checks.iter().find(|c| c.id == id).unwrap().outcome;
        for id in ["connect", "model", "hardware", "binding"] {
            assert_eq!(outcome(id), CheckOutcome::Passed, "{id}");
        }
        assert_eq!(outcome("software"), CheckOutcome::Failed);
        for id in ["deploy", "weights", "gpu", "signature"] {
            assert_eq!(outcome(id), CheckOutcome::NotRun, "{id}");
        }
        assert!(!verification_report("org/M", None, checks, 1).passed);
    }

    #[test]
    fn the_recommended_model_is_flagged_and_used_by_default() {
        let model = |id: &str, label: Option<&'static str>| NearAiModel {
            id: id.into(),
            host: format!("{id}.completions.near.ai"),
            display_name: id.into(),
            description: None,
            context_length: Some(131_072),
            max_output_tokens: None,
            input_price: None,
            output_price: None,
            suggestion: label.map(|label| nearai::Suggestion { label, reason: "r" }),
        };
        let models = vec![model("fast", Some("Fastest and cheapest")), model("rec", Some("Recommended")), model("other", None)];
        let listed = cloud_models(&models);
        assert_eq!(listed.iter().filter(|m| m.recommended).map(|m| m.id.as_str()).collect::<Vec<_>>(), ["rec"]);
        assert_eq!(recommended(&models[2..]).unwrap().id, "other", "falls back to the first listed");
    }
}
