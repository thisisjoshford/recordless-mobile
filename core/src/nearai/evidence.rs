//! Offline checks on a NEAR AI attestation report.
//!
//! These tie the pieces of the report together: the verified quote must bind
//! this request's nonce, the TLS key we are talking to, and the key that signs
//! responses; the measured configuration must match the deployment manifest;
//! and the deploy manager's action log must be bound to its own quote.
use std::collections::{BTreeMap, BTreeSet};

use k256::ecdsa::{RecoveryId, Signature, VerifyingKey};
use serde::Deserialize;
use sha2::{Digest, Sha256, Sha384};
use sha3::Keccak256;

#[derive(Deserialize)]
pub(crate) struct AttestationReport {
    pub model_name: String,
    pub signing_address: String,
    pub signing_algo: String,
    pub intel_quote: String,
    pub nvidia_payload: String,
    pub info: Info,
    pub tls_cert_fingerprint: String,
    /// NEAR AI's deploy manager. Other enclave hosts do not have one.
    #[serde(default)]
    pub compose_manager_attestation: Option<ComposeManagerAttestation>,
}

#[derive(Deserialize)]
pub(crate) struct Info {
    pub tcb_info: TcbInfo,
}

#[derive(Deserialize)]
pub(crate) struct TcbInfo {
    pub app_compose: String,
    pub event_log: Vec<Event>,
}

#[derive(Deserialize)]
pub(crate) struct Event {
    pub imr: u32,
    pub event_type: u32,
    pub digest: String,
    pub event: String,
    pub event_payload: String,
}

#[derive(Deserialize)]
pub(crate) struct ComposeManagerAttestation {
    pub actions: Vec<serde_json::Value>,
    pub actions_hash: String,
    pub nonce: String,
    pub quote: String,
}

fn decode_hex(label: &str, value: &str) -> Result<Vec<u8>, String> {
    hex::decode(value.trim_start_matches("0x")).map_err(|_| format!("Attestation {label} is not valid hex"))
}

fn decode_fixed<const N: usize>(label: &str, value: &str) -> Result<[u8; N], String> {
    decode_hex(label, value)?
        .try_into()
        .map_err(|_| format!("Attestation {label} has the wrong length"))
}

/// report_data = SHA256(signing_address || tls_spki_sha256) || nonce
pub(crate) fn check_report_data(
    report_data: &[u8; 64],
    signing_address: &str,
    tls_fingerprint: &str,
    nonce: &[u8; 32],
) -> Result<(), String> {
    let mut first = Sha256::new();
    first.update(decode_hex("signing address", signing_address)?);
    first.update(decode_fixed::<32>("TLS fingerprint", tls_fingerprint)?);
    if report_data[..32] != first.finalize()[..] {
        return Err("The quote does not bind this TLS key and signing key".into());
    }
    if report_data[32..] != nonce[..] {
        return Err("The quote was not produced for this request".into());
    }
    Ok(())
}

fn event_digest(event: &Event) -> Result<[u8; 48], String> {
    let mut hasher = Sha384::new();
    hasher.update(event.event_type.to_le_bytes());
    hasher.update(b":");
    hasher.update(event.event.as_bytes());
    hasher.update(b":");
    hasher.update(decode_hex("event payload", &event.event_payload)?);
    Ok(hasher.finalize().into())
}

/// Replay the runtime events into RTMR3 and return each application event's payload.
pub(crate) fn replay_rtmr3(events: &[Event], rt_mr3: &[u8; 48]) -> Result<Vec<(String, Vec<u8>)>, String> {
    let mut register = [0u8; 48];
    let mut app_events = Vec::new();
    for event in events.iter().filter(|e| e.imr == 3) {
        let digest = event_digest(event)?;
        if digest != decode_fixed::<48>("event digest", &event.digest)? {
            return Err(format!("Event {} does not match its digest", event.event));
        }
        let mut hasher = Sha384::new();
        hasher.update(register);
        hasher.update(digest);
        register = hasher.finalize().into();
        app_events.push((event.event.clone(), decode_hex("event payload", &event.event_payload)?));
    }
    if &register != rt_mr3 {
        return Err("The event log does not match the measured RTMR3".into());
    }
    Ok(app_events)
}

fn single_event<'a>(events: &'a [(String, Vec<u8>)], name: &str) -> Result<&'a [u8], String> {
    let mut matches = events.iter().filter(|(event, _)| event == name);
    match (matches.next(), matches.next()) {
        (Some((_, payload)), None) => Ok(payload),
        _ => Err(format!("The event log must contain exactly one {name} event")),
    }
}

/// Check the deployment manifest against the measurements and our policy.
/// Returns the manifest hash.
pub(crate) fn check_app_compose(
    app_compose: &str,
    mr_config_id: &[u8; 48],
    events: &[(String, Vec<u8>)],
) -> Result<[u8; 32], String> {
    let compose_hash: [u8; 32] = Sha256::digest(app_compose.as_bytes()).into();
    let mut expected_config = [0u8; 48];
    expected_config[0] = 1;
    expected_config[1..33].copy_from_slice(&compose_hash);
    if mr_config_id != &expected_config {
        return Err("The deployment manifest does not match the measured configuration".into());
    }
    if single_event(events, "compose-hash")? != compose_hash {
        return Err("The deployment manifest does not match the boot event log".into());
    }

    let key_provider: serde_json::Value = serde_json::from_slice(single_event(events, "key-provider")?)
        .map_err(|_| "The key-provider event is not valid JSON")?;
    if key_provider["name"] != "kms" {
        return Err("The enclave does not get its keys from the attested key service".into());
    }

    let manifest: serde_json::Value =
        serde_json::from_str(app_compose).map_err(|_| "The deployment manifest is not valid JSON")?;
    if manifest["public_logs"] != false {
        return Err("The enclave publishes its container logs".into());
    }
    if manifest["kms_enabled"] != true || manifest["local_key_provider_enabled"] != false {
        return Err("The enclave does not use the attested key service".into());
    }
    let compose = manifest["docker_compose_file"]
        .as_str()
        .ok_or("The deployment manifest has no compose file")?;
    // A variable the deployment is allowed to set can replace whatever an
    // image line defaults to, so the pin only holds for the rest.
    let allowed_envs: Vec<&str> = manifest["allowed_envs"]
        .as_array()
        .map(|envs| envs.iter().filter_map(serde_json::Value::as_str).collect())
        .unwrap_or_default();
    check_compose_images(compose, &allowed_envs)?;
    Ok(compose_hash)
}

/// Every service must run a prebuilt image pinned by digest.
fn check_compose_images(compose: &str, allowed_envs: &[&str]) -> Result<(), String> {
    let compose = parse_compose(compose, "The deployment manifest's compose file")?;
    let services = compose
        .get("services")
        .and_then(serde_yaml_ng::Value::as_mapping)
        .filter(|services| !services.is_empty())
        .ok_or("The compose file lists no services")?;
    for (name, service) in services {
        let name = name.as_str().unwrap_or("?");
        if service.get("build").is_some() {
            return Err(format!("Service {name} is built on the host instead of using a pinned image"));
        }
        let image = service
            .get("image")
            .and_then(serde_yaml_ng::Value::as_str)
            .ok_or_else(|| format!("Service {name} has no image"))?;
        if !digest_pinned(image, allowed_envs) {
            return Err(format!("Service {name} uses an unpinned image: {image}"));
        }
    }
    Ok(())
}

fn canonical_json(value: &serde_json::Value, out: &mut String) {
    match value {
        serde_json::Value::Object(map) => {
            let mut entries: Vec<_> = map.iter().collect();
            entries.sort_by(|a, b| a.0.cmp(b.0));
            out.push('{');
            for (i, (key, item)) in entries.into_iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::Value::String(key.clone()).to_string());
                out.push(':');
                canonical_json(item, out);
            }
            out.push('}');
        }
        serde_json::Value::Array(items) => {
            out.push('[');
            for (i, item) in items.iter().enumerate() {
                if i > 0 {
                    out.push(',');
                }
                canonical_json(item, out);
            }
            out.push(']');
        }
        other => out.push_str(&other.to_string()),
    }
}

/// Every deploy-manager image the measured manifest mentions, its launch
/// script included.
///
/// This is weaker than it looks: the manifest's compose file takes the image
/// from `${COMPOSE_MANAGER_IMAGE:-<default>}`, and the launch script reads that
/// variable from a file on a Docker volume that nothing measures, so the
/// manifest names the candidates rather than choosing between them. A manager
/// running an image from outside this set is therefore treated as unread, not
/// as proof of wrongdoing.
pub(crate) fn measured_manager_images(app_compose: &str) -> Vec<String> {
    const PREFIX: &str = "nearaidev/compose-manager@sha256:";
    let mut images = Vec::new();
    for (at, _) in app_compose.match_indices(PREFIX) {
        let digest: String = app_compose[at + PREFIX.len()..]
            .chars()
            .take_while(|c| c.is_ascii_hexdigit())
            .collect();
        if digest.len() == 64 {
            images.push(format!("{PREFIX}{digest}"));
        }
    }
    images.sort();
    images.dedup();
    images
}

/// The deploy manager's action log must hash to the value bound into its quote,
/// and must come from a deploy manager image. Returns the number of logged
/// actions, and whether the manager running now is one the measured manifest
/// names: when it is not, the log is still genuine, but what selected it was
/// not measured, so the stages that read it are left unread.
pub(crate) fn check_compose_manager(
    attestation: &ComposeManagerAttestation,
    quote_report_data: &[u8; 64],
    nonce: &[u8; 32],
    measured_images: &[String],
) -> Result<(usize, bool), String> {
    let mut canonical = String::new();
    canonical_json(&serde_json::Value::Array(attestation.actions.clone()), &mut canonical);
    let actions_hash: [u8; 32] = Sha256::digest(canonical.as_bytes()).into();
    if actions_hash != decode_fixed::<32>("actions hash", &attestation.actions_hash)? {
        return Err("The deploy log does not match its hash".into());
    }
    if decode_fixed::<32>("deploy log nonce", &attestation.nonce)? != *nonce {
        return Err("The deploy log was not produced for this request".into());
    }
    if quote_report_data[..32] != actions_hash || quote_report_data[32..] != nonce[..] {
        return Err("The deploy log is not bound to its quote".into());
    }
    let started: Vec<&str> = attestation
        .actions
        .iter()
        .filter(|a| a["action"] == "compose_manager_started")
        .filter_map(|a| a["image"].as_str())
        .collect();
    if started.is_empty() {
        return Err("The deploy log does not record the deploy manager starting".into());
    }
    if let Some(image) = started.iter().find(|i| !i.starts_with("nearaidev/compose-manager@sha256:")) {
        return Err(format!("An unexpected deploy manager ran: {image}"));
    }
    // The manifest's compose file can take this image from a variable set
    // outside anything measured, so the manifest names candidates rather than
    // choosing. An image from outside that set means the log was written by a
    // manager whose selection we cannot see; the caller leaves the stages that
    // read it unread rather than failing, since a routine manager upgrade
    // looks exactly like this.
    let current = started.last().expect("started is not empty");
    let manager_measured = measured_images.iter().any(|image| image == current);
    Ok((attestation.actions.len(), manager_measured))
}

#[derive(Deserialize, Clone)]
pub(crate) struct ChatSignature {
    pub text: String,
    pub signature: String,
    pub signing_address: String,
    #[serde(default)]
    pub signature_kind: Option<String>,
}

fn eth_address(key: &VerifyingKey) -> [u8; 20] {
    let point = key.to_encoded_point(false);
    let hash = Keccak256::digest(&point.as_bytes()[1..]);
    hash[12..].try_into().expect("20 bytes")
}

/// The response must be signed by the attested model key over the exact
/// request and response bytes. The model TEE signs
/// `{model_id}:{request_hash}:{response_hash}`, and a signature that leaves the
/// model out is refused.
pub(crate) fn check_chat_signature(
    signature: &ChatSignature,
    model: &str,
    request_body: &[u8],
    response_body: &[u8],
    attested_address: &str,
) -> Result<(), String> {
    if signature.signature_kind.as_deref().is_some_and(|kind| kind != "provider_tee") {
        return Err("The response was not signed by the model enclave".into());
    }
    // NEAR AI signs `{model}:{sha256(request)}:{sha256(response)}`, so the
    // model the reply came from is signed too, not merely claimed. A signature
    // that leaves it out is refused rather than accepted as unbound.
    let (request_hash, response_hash) = match signature.text.rsplitn(3, ':').collect::<Vec<_>>().as_slice() {
        [resp, req, signed_model] if *signed_model == model => (*req, *resp),
        [_, _, _] => return Err("The response signature is for a different model".into()),
        _ => return Err("The response signature does not name the model".into()),
    };
    if request_hash != hex::encode(Sha256::digest(request_body)) {
        return Err("The signed request does not match what was sent".into());
    }
    if response_hash != hex::encode(Sha256::digest(response_body)) {
        return Err("The signed response does not match what was received".into());
    }

    let raw = decode_hex("response signature", &signature.signature)?;
    if raw.len() != 65 {
        return Err("The response signature has the wrong length".into());
    }
    let sig = Signature::from_slice(&raw[..64]).map_err(|_| "The response signature is malformed")?;
    // Ethereum signatures carry v as 27/28; some signers use 0/1.
    let recovery = match raw[64] {
        0 | 27 => RecoveryId::from_byte(0),
        1 | 28 => RecoveryId::from_byte(1),
        _ => None,
    }
    .ok_or("The response signature has an invalid recovery id")?;
    let mut message = Keccak256::new();
    message.update(format!("\x19Ethereum Signed Message:\n{}", signature.text.len()).as_bytes());
    message.update(signature.text.as_bytes());
    let key = VerifyingKey::recover_from_prehash(&message.finalize(), &sig, recovery)
        .map_err(|_| "The response signature did not verify")?;
    let signer = eth_address(&key);
    let attested: [u8; 20] = decode_fixed("signing address", attested_address)?;
    if signer != attested || !signature.signing_address.eq_ignore_ascii_case(attested_address) {
        return Err("The response was not signed by the attested enclave".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {    /// vLLM takes the model as its first argument. Such a service used to be
    /// skipped in silence, which let a decoy answer for the model unopposed.
    #[test]
    fn a_model_given_as_the_first_argument_is_read() {
        let compose = format!(
            "services:\n  server:\n    image: vllm/vllm-openai@sha256:{}\n    command: >\n      Qwen/Qwen3-VL-30B-A3B-Instruct-FP8\n      --revision d9748a51ae66354c4dad665aab2c71f26cf2c8cd\n      --served-model-name Qwen/Qwen3-VL-30B-A3B-Instruct\n",
            "a".repeat(64)
        );
        let reading =
            find_model_services(&compose, Scope::Named(&["server"]), "Qwen/Qwen3-VL-30B-A3B-Instruct")
                .unwrap();
        assert_eq!(reading.services[0].weights, "Qwen/Qwen3-VL-30B-A3B-Instruct-FP8");
        assert!(reading.unreadable.is_none());
    }

    /// A service that answers for the model but does not say what it loads is
    /// a gap, not an absence: concluding anything would let a decoy stand in.
    #[test]
    fn a_service_that_serves_the_model_unreadably_is_a_gap() {
        let compose = format!(
            "services:\n  server:\n    image: vllm/vllm-openai@sha256:{}\n    command: >\n      --served-model-name org/Model\n",
            "b".repeat(64)
        );
        let reading = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap();
        assert!(reading.unreadable.is_some() && reading.services.is_empty());
    }

    /// A backslash makes the next character literal, so it cannot open a
    /// quoted region. Reading it as a quote let a crafted command show one
    /// model while the server loaded another.
    #[test]
    fn a_backslash_does_not_open_a_quote() {
        let words = shell_words(r#"launch --chat-template \" --model-path org/Backdoored"#).unwrap();
        assert_eq!(words.last().unwrap(), "org/Backdoored");
        assert_eq!(words[2], "\"");
        // A line that does not parse is not "no flags".
        assert!(shell_words("--model-path \"org/Unterminated").is_none());
        // Real quoting still groups.
        let grouped = shell_words(r#"sh -c 'while :; do sleep 6h; nginx -s reload; done'"#).unwrap();
        assert_eq!(grouped.len(), 3);
    }

    /// Only `${VAR:+literal}` is readable: it expands to text that is right
    /// here. Every other form takes its value from the host.
    #[test]
    fn only_a_fixed_substitution_is_readable() {
        assert!(readable_substitutions("${DSV4_RETURN_HIDDEN_STATES:+--enable-return-hidden-states}"));
        assert!(readable_substitutions("plain"));
        for word in ["${MODEL}", "$MODEL", "${MODEL:-org/Default}", "${X:+--model-path}"] {
            assert!(!readable_substitutions(word), "{word} must not be readable");
        }
    }

    /// An asterisk in a glob, a regular expression or a comment is not an
    /// alias, and counting it as one would refuse real files.
    #[test]
    fn only_real_aliases_count_toward_the_expansion_budget() {
        let globs = format!(
            "# see *.yaml\nservices:\n  a:\n    command: \"ls /var/log/*/*.log; py 1024 ** 3\"\n    image: x/a@sha256:{}\n",
            "0".repeat(64)
        );
        let padded = format!("{globs}{}", "# padding to make length matter\n".repeat(2_000));
        assert!(parse_compose(&padded, "test").is_ok());
    }

    /// A container name belongs to the machine, so a stop under any file stops
    /// it everywhere: NEAR AI reuses model-server names across files, and stops
    /// them under a different file than the one that started them.
    #[test]
    fn a_stop_under_any_file_stops_that_container_everywhere() {
        let actions = serde_json::json!([
            {"action": "compose_up", "commit": "a".repeat(40), "file": "a.yaml", "file_sha256": "1".repeat(64)},
            {"action": "compose_up", "commit": "c".repeat(40), "file": "c.yaml", "file_sha256": "3".repeat(64), "services": ["shared"]},
            {"action": "compose_down", "commit": "b".repeat(40), "file": "b.yaml", "services": ["shared"]},
        ]);
        let running = running_services(actions.as_array().unwrap());
        assert!(!running.named.contains_key("shared"), "the container is stopped");
        assert!(
            running.whole["a.yaml"].stopped.contains("shared"),
            "no whole-file record may still claim it"
        );
    }


    use super::*;

    /// A compose file shaped like NEAR AI's: the model server's command lives
    /// in a top-level anchor, merged into the service with `<<:`.
    const COMPOSE: &str = r#"
x-server: &server
  image: registry.example/sglang@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  command: >
    python3 -m sglang.launch_server
    --model-path org/Model-FP8
    --revision 017b9c7af6b5689d5dd426a76e0bc077eb5ca20a
    --served-model-name org/Model
services:
  model-server-r1:
    <<: *server
  model-server-r2:
    <<: *server
  built-here:
    image: local-thing
    build:
      context: .
    command: >
      serve --model-path org/Model --served-model-name org/Other
  proxy:
    image: registry.example/proxy@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
"#;

    /// NEAR AI's GLM files chain anchors: the service merges a variant that
    /// overrides the command and itself merges the anchor holding the image.
    #[test]
    fn an_anchor_merged_through_another_anchor_is_read() {
        let compose = format!(
            r#"
x-runtime: &runtime
  runtime: nvidia
x-common: &common
  <<: *runtime
  image: registry.example/sglang@sha256:{digest}
  command: serve --model-path org/Old --served-model-name org/Model
x-variant: &variant
  <<: *common
  command: >
    serve --model-path /root/.cache/huggingface/hub/models--org--Model-FP8/snapshots/{revision}
    --served-model-name org/Model
services:
  server:
    <<: *variant
    labels:
      instance: "1"
"#,
            digest = "a".repeat(64),
            revision = "017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"
        );
        let found = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap();
        let server = &found.services[0];
        assert!(server.image.ends_with(&"a".repeat(64)));
        // The nearer anchor's command wins over the one it merges.
        assert_eq!(server.weights, "org/Model-FP8");
        assert_eq!(server.revision.as_deref(), Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"));
    }

    /// A real deployed file, when one is to hand: `NEARAI_COMPOSE=<path>
    /// NEARAI_MODEL=<served name> cargo test a_deployed_file -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn a_deployed_file_can_be_read() {
        let compose = std::fs::read_to_string(std::env::var("NEARAI_COMPOSE").unwrap()).unwrap();
        let model = std::env::var("NEARAI_MODEL").unwrap();
        let found = find_model_services(&compose, Scope::WholeFile(&[]), &model).unwrap();
        println!("{:#?}", found);
        assert!(!found.services.is_empty());
    }

    /// A sequence entry is one argument. Splitting it on whitespace let a
    /// quoted value be read as a flag, and with last-value-wins that value
    /// decided what the stage reported.
    #[test]
    fn a_quoted_value_cannot_pose_as_a_flag() {
        let listed = format!(
            r#"
services:
  server:
    image: registry.example/sglang@sha256:{digest}
    command: ["launch", "--model-path", "org/Real", "--revision", "017b9c7af6b5689d5dd426a76e0bc077eb5ca20a",
              "--served-model-name", "org/Model", "--chat-template", "--model-path org/Fake"]
"#,
            digest = "a".repeat(64)
        );
        let found = find_model_services(&listed, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Real", "the quoted argument is not a flag");

        // The same in a shell command line: the quotes make it one argument.
        let inline = format!(
            "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path org/Real --revision 017b9c7af6b5689d5dd426a76e0bc077eb5ca20a\n      --served-model-name org/Model --chat-template \"--model-path org/Fake\"\n",
            "a".repeat(64)
        );
        let found = find_model_services(&inline, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Real");
    }

    /// argparse accepts abbreviations and underscores, so the checker has to
    /// read those the way the server will.
    #[test]
    fn abbreviated_and_underscored_flags_are_read_as_the_server_reads_them() {
        for spelling in ["--model-pa", "--model_path", "--mode"] {
            let compose = format!(
                "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path org/Real --revision 017b9c7af6b5689d5dd426a76e0bc077eb5ca20a {spelling} org/Swapped\n      --served-model-name org/Model\n",
                "b".repeat(64)
            );
            let found = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap();
            assert_eq!(found.services[0].weights, "org/Swapped", "{spelling} should win, as it does for the server");
        }
        // A longer flag that merely starts the same way is not the model flag.
        assert!(names_flag("--model_path", "--model-path"));
        assert!(!names_flag("--model-loader-extra-config", "--model-path"));
    }

    /// A revision is what makes the weights a fixed thing, so a branch name or
    /// a variable leaves the stage unread rather than passing.
    #[test]
    fn only_a_commit_counts_as_a_pinned_revision() {
        for revision in ["main", "refs/heads/main", "v1.0", "1234567"] {
            let compose = format!(
                "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path org/Model --revision \"{revision}\" --served-model-name org/Model\n",
                "c".repeat(64)
            );
            let found = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap();
            assert_eq!(found.services[0].revision, None, "{revision} does not fix the weights");
        }
        assert_eq!(pinned_revision(Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a")).as_deref(),
                   Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"));
        // A revision taken from the host's environment is not readable at all.
        let from_a_variable = format!(
            "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path org/Model --revision ${{REV}} --served-model-name org/Model\n",
            "c".repeat(64)
        );
        let reading = find_model_services(&from_a_variable, Scope::Named(&["server"]), "org/Model").unwrap();
        assert!(reading.unreadable.is_some() && reading.services.is_empty());
    }

    /// The cache-path reading used to run first and discard the part of the
    /// path holding the substitution.
    #[test]
    fn a_substitution_inside_a_cache_path_is_still_refused() {
        let compose = format!(
            "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path ${{DIR}}/models--org--Model/snapshots/deadbeef --served-model-name org/Model\n",
            "d".repeat(64)
        );
        let reading = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap();
        assert!(reading.unreadable.is_some() && reading.services.is_empty(), "{reading:?}");
    }

    /// A deployed file's variables come from the host, so no substitution in a
    /// serving image counts as pinned, whatever its default.
    #[test]
    fn a_deployed_image_behind_any_variable_is_unpinned() {
        let compose = format!(
            "services:\n  server:\n    image: \"${{IMAGE:-registry.example/sglang@sha256:{}}}\"\n    command: >\n      launch --model-path org/Model --served-model-name org/Model\n",
            "e".repeat(64)
        );
        let error = find_model_services(&compose, Scope::Named(&["server"]), "org/Model").unwrap_err();
        assert!(error.contains("unpinned image"), "{error}");
    }

    #[test]
    fn the_running_deploy_manager_must_be_one_the_manifest_names() {
        let report = fixture();
        let app_compose = &report.info.tcb_info.app_compose;
        let images = measured_manager_images(app_compose);
        assert!(images.len() >= 2, "the manifest names a default and a launch-script override");
        let attestation = report.compose_manager_attestation.unwrap();
        let running = attestation
            .actions
            .iter()
            .filter(|a| a["action"] == "compose_manager_started")
            .filter_map(|a| a["image"].as_str())
            .next_back()
            .unwrap();
        assert!(images.iter().any(|image| image == running), "{running} should be measured");
        // An image from nowhere in the manifest is refused even with the right
        // repository prefix.
        assert!(!images.contains(&format!("nearaidev/compose-manager@sha256:{}", "f".repeat(64))));
    }

    /// A document small enough to pass a byte cap can still expand into a tree
    /// that exhausts memory, because every alias copies what it points at.
    #[test]
    fn a_compose_file_that_would_expand_enormously_is_refused() {
        let anchor = format!("x-a: &a\n  command: \"{}\"\n", "w".repeat(20_000));
        let bomb = format!("{anchor}services:\n{}", "  s{i}:\n    <<: *a\n".repeat(600));
        let error = find_model_services(&bomb, Scope::WholeFile(&[]), "org/Model").unwrap_err();
        assert!(error.contains("expand"), "{error}");
    }

    #[test]
    fn the_deploy_log_maps_each_running_service_to_the_file_that_started_it() {
        let actions = fixture().compose_manager_attestation.unwrap().actions;
        let running = running_services(&actions);
        // The fixture's newest deployment started the proxies, while the model
        // servers still run from the versions that brought them up.
        let (_, proxy) = running.named.get("proxy-dsv4-flash").expect("proxy is running");
        let (_, server) =
            running.named.get("model-sg-dsv4-flash-fp4-tp2-r1").expect("model server is running");
        assert_eq!(proxy.path, "prod/small-models.yaml");
        assert_ne!(proxy.commit, server.commit);
        assert_eq!(server.file_sha256.len(), 64);
        assert!(!running.named.contains_key("vllm-dsv4-flash"));
    }

    /// `docker compose up`/`down` with no service arguments covers every
    /// service in the file. The fixture has 21 and 8 of those, and reading
    /// them as no-ops leaves services that were stopped looking live, or
    /// attributes a live one to a file version it no longer runs.
    #[test]
    fn whole_file_deployments_cover_every_service_in_the_file() {
        let actions = fixture().compose_manager_attestation.unwrap().actions;
        let running = running_services(&actions);
        // This one's file was brought down as a whole after its last named start.
        assert!(!running.named.contains_key("proxy-glm51-awq-tp4"));
        // And this file was last started as a whole, so it is tracked by path
        // with no stale per-service version left behind.
        let whole = running.whole.get("prod/small-models.yaml").expect("file runs as a whole");
        assert!(running.named.values().all(|(_, started)| started.path != "prod/small-models.yaml"
            || started.commit != whole.deployment.commit));

        let stopped = serde_json::json!([
            {"action": "compose_up", "commit": "a".repeat(40), "file": "f.yaml", "file_sha256": "1".repeat(64), "services": ["one", "two"]},
            {"action": "compose_down", "commit": "a".repeat(40), "file": "f.yaml"},
        ]);
        let running = running_services(stopped.as_array().unwrap());
        assert!(running.named.is_empty() && running.whole.is_empty());
    }

    /// A whole-file start is the only record such a service has, so a later
    /// stop by name has to be remembered against it, or the service looks live
    /// forever. NEAR AI's own logs do exactly this.
    #[test]
    fn a_service_stopped_by_name_stays_stopped_under_a_whole_file_start() {
        let actions = serde_json::json!([
            {"action": "compose_up", "commit": "a".repeat(40), "file": "f.yaml", "file_sha256": "1".repeat(64)},
            {"action": "compose_down", "commit": "a".repeat(40), "file": "f.yaml", "services": ["old-server"]},
        ]);
        let running = running_services(actions.as_array().unwrap());
        let whole = running.whole.get("f.yaml").expect("the file runs as a whole");
        assert!(whole.stopped.contains("old-server"));

        // Starting the whole file again clears what had been stopped.
        let restarted = serde_json::json!([
            {"action": "compose_up", "commit": "a".repeat(40), "file": "f.yaml", "file_sha256": "1".repeat(64)},
            {"action": "compose_down", "commit": "a".repeat(40), "file": "f.yaml", "services": ["old-server"]},
            {"action": "compose_up", "commit": "b".repeat(40), "file": "f.yaml", "file_sha256": "2".repeat(64)},
        ]);
        let running = running_services(restarted.as_array().unwrap());
        assert!(running.whole["f.yaml"].stopped.is_empty());
    }

    #[test]
    fn a_deployment_without_a_file_hash_stops_counting_as_running() {
        let actions = serde_json::json!([
            {"action": "compose_up", "commit": "a".repeat(40), "file": "f.yaml", "file_sha256": "1".repeat(64), "services": ["one"]},
            {"action": "compose_up", "commit": "b".repeat(40), "file": "f.yaml", "services": ["one"]},
        ]);
        let running = running_services(actions.as_array().unwrap());
        assert!(running.named.is_empty(), "an uncheckable restart leaves nothing to check");
    }

    #[test]
    fn the_service_serving_a_model_is_read_through_its_merge_keys() {
        let found =
            find_model_services(COMPOSE, Scope::Named(&["model-server-r1", "proxy"]), "org/Model")
                .unwrap();
        assert_eq!(found.services.len(), 1);
        assert_eq!(found.services[0].service, "model-server-r1");
        assert_eq!(found.services[0].weights, "org/Model-FP8");
        assert_eq!(found.services[0].revision.as_deref(), Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"));
    }

    #[test]
    fn a_whole_file_deployment_covers_all_its_services_but_what_a_newer_one_took_over() {
        let all = find_model_services(COMPOSE, Scope::WholeFile(&[]), "org/Model").unwrap().services;
        assert_eq!(all.len(), 2, "both replicas serve it");
        let rest = find_model_services(COMPOSE, Scope::WholeFile(&["model-server-r1"]), "org/Model")
            .unwrap()
            .services;
        assert_eq!(rest.len(), 1);
        assert_eq!(rest[0].service, "model-server-r2");
    }

    #[test]
    fn only_services_running_now_can_answer_for_a_model() {
        assert!(find_model_services(COMPOSE, Scope::Named(&["proxy"]), "org/Model").unwrap().services.is_empty());
        assert!(find_model_services(COMPOSE, Scope::Named(&["model-server-r2"]), "org/Nothing")
            .unwrap()
            .services
            .is_empty());
    }

    #[test]
    fn a_model_served_from_an_image_the_host_builds_is_refused() {
        let error =
            find_model_services(COMPOSE, Scope::Named(&["built-here"]), "org/Other").unwrap_err();
        assert!(error.contains("built on the host"), "{error}");
    }

    /// The serving binaries parse with argparse, where the last value of a
    /// repeated option wins. Reading the first would let a compose file
    /// advertise one model while running another.
    #[test]
    fn a_repeated_flag_is_read_the_way_the_server_reads_it() {
        let compose = r#"
services:
  server:
    image: registry.example/sglang@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
    command: >
      launch --model-path org/Trusted-FP8 --revision 017b9c7af6b5689d5dd426a76e0bc077eb5ca20a
      --model-path org/Swapped-FP8 --revision 7872f01b1d1fe23eabc4c98b48bffcef5a386062
      --served-model-name org/Model
"#;
        let found = find_model_services(compose, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Swapped-FP8");
        assert_eq!(found.services[0].revision.as_deref(), Some("7872f01b1d1fe23eabc4c98b48bffcef5a386062"));
    }

    #[test]
    fn flags_read_the_same_written_with_an_equals_sign() {
        let listed = r#"
services:
  server:
    image: registry.example/vllm@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    command: ["--model=org/Model-FP8", "--revision=017b9c7af6b5689d5dd426a76e0bc077eb5ca20a", "--served-model-name=org/Model"]
"#;
        let found = find_model_services(listed, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Model-FP8");
        assert_eq!(found.services[0].revision.as_deref(), Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"));

        // A command line is shell-split, so quotes there are the shell's and
        // the server never sees them.
        let inline = r#"
services:
  server:
    image: registry.example/vllm@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
    command: >
      launch --model 'org/Model-FP8' --revision "017b9c7af6b5689d5dd426a76e0bc077eb5ca20a" --served-model-name org/Model
"#;
        let found = find_model_services(inline, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Model-FP8");
        assert_eq!(found.services[0].revision.as_deref(), Some("017b9c7af6b5689d5dd426a76e0bc077eb5ca20a"));
    }

    /// `--model` is an abbreviation of `--model-path` as far as argparse is
    /// concerned, so both spellings are the same flag and the last one wins.
    #[test]
    fn the_two_spellings_of_the_model_flag_are_one_flag() {
        let compose = r#"
services:
  server:
    image: registry.example/vllm@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
    command: >
      launch --model-path org/One --model org/Two --served-model-name org/Model
"#;
        let found = find_model_services(compose, Scope::Named(&["server"]), "org/Model").unwrap();
        assert_eq!(found.services[0].weights, "org/Two");
    }

    /// The image is the whole point of the stage, so nothing the host can
    /// change after the fact counts as pinned.
    #[test]
    fn a_model_served_from_an_image_that_is_not_fully_pinned_is_refused() {
        for image in [
            "registry.example/sglang:latest",
            "registry.example/sglang@sha256:abcd",
            "registry.example/sglang@sha256:zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz",
            "${IMAGE}",
            "${IMAGE:-registry.example/sglang:latest}",
            "@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        ] {
            let compose = format!(
                "services:\n  server:\n    image: \"{image}\"\n    command: >\n      launch --model-path org/Model\n"
            );
            let error = find_model_services(&compose, Scope::Named(&["server"]), "org/Model")
                .unwrap_err();
            assert!(error.contains("unpinned image"), "{image}: {error}");
        }
    }

    /// Weights the host can still point elsewhere are not a model identity.
    #[test]
    fn weights_that_name_nothing_fixed_are_refused() {
        for weights in ["/data/weights", "justaname"] {
            let compose = format!(
                "services:\n  server:\n    image: registry.example/sglang@sha256:{}\n    command: >\n      launch --model-path \"{weights}\" --served-model-name org/Model\n",
                "f".repeat(64)
            );
            let error = find_model_services(&compose, Scope::Named(&["server"]), "org/Model")
                .unwrap_err();
            assert!(error.contains("does not name a fixed model"), "{weights}: {error}");
        }
    }

    #[test]
    fn weights_from_a_local_cache_path_are_read_as_a_repo_and_snapshot() {
        let (weights, revision) = named_weights(
            "/root/.cache/huggingface/hub/models--zai-org--GLM-5.3-Flash/snapshots/84c6a6aa",
            None,
        );
        assert_eq!(weights, "zai-org/GLM-5.3-Flash");
        assert_eq!(revision.as_deref(), Some("84c6a6aa"));
        // A plain repo id is already what it claims to be.
        assert_eq!(named_weights("Qwen/Qwen3.8-27B-FP8", None).0, "Qwen/Qwen3.8-27B-FP8");
    }

    #[test]
    fn a_model_named_only_by_its_weights_still_matches() {
        let compose = format!(
            "services:\n  server:\n    image: registry.example/vllm@sha256:{}\n    command: [\"--model\", \"org/Plain\"]\n",
            "1".repeat(64)
        );
        let found =
            find_model_services(&compose, Scope::Named(&["server"]), "org/Plain").unwrap();
        assert_eq!(found.services[0].weights, "org/Plain");
        assert_eq!(found.services[0].revision, None);
    }

    #[test]
    fn an_image_pinned_behind_a_settable_variable_is_not_pinned() {
        let pinned = format!("${{IMAGE:-x/a@sha256:{}}}", "0".repeat(64));
        assert!(digest_pinned(&pinned, &[]));
        assert!(!digest_pinned(&pinned, &["IMAGE"]), "a settable variable replaces the default");
    }

    fn fixture() -> AttestationReport {
        serde_json::from_str(include_str!("testdata/attestation.json")).unwrap()
    }

    fn fixture_nonce() -> [u8; 32] {
        decode_fixed("nonce", "590e542ce34282749d9e4242d56cc5de47b89d9a6ac65ee189bf8d309a91145b").unwrap()
    }

    fn fixture_quote() -> dcap_qvl::quote::TDReport10 {
        let quote = dcap_qvl::quote::Quote::parse(&hex::decode(fixture().intel_quote).unwrap()).unwrap();
        match quote.report {
            dcap_qvl::quote::Report::TD10(report) => report,
            dcap_qvl::quote::Report::TD15(report) => report.base,
            _ => panic!("not a TD quote"),
        }
    }

    #[test]
    fn report_data_binds_tls_key_signer_and_nonce() {
        let report = fixture();
        let td = fixture_quote();
        let nonce = fixture_nonce();
        check_report_data(&td.report_data, &report.signing_address, &report.tls_cert_fingerprint, &nonce).unwrap();

        let mut other_nonce = nonce;
        other_nonce[0] ^= 1;
        assert!(check_report_data(&td.report_data, &report.signing_address, &report.tls_cert_fingerprint, &other_nonce).is_err());
        let other_fp = format!("00{}", &report.tls_cert_fingerprint[2..]);
        assert!(check_report_data(&td.report_data, &report.signing_address, &other_fp, &nonce).is_err());
    }

    #[test]
    fn manifest_matches_measurements() {
        let report = fixture();
        let td = fixture_quote();
        let events = replay_rtmr3(&report.info.tcb_info.event_log, &td.rt_mr3).unwrap();
        check_app_compose(&report.info.tcb_info.app_compose, &td.mr_config_id, &events).unwrap();

        let tampered = report.info.tcb_info.app_compose.replace("\"public_logs\": false", "\"public_logs\": true");
        assert_ne!(tampered, report.info.tcb_info.app_compose);
        assert!(check_app_compose(&tampered, &td.mr_config_id, &events).is_err());

        let mut wrong = td.rt_mr3;
        wrong[0] ^= 1;
        assert!(replay_rtmr3(&report.info.tcb_info.event_log, &wrong).is_err());
    }

    #[test]
    fn deploy_log_is_bound_to_its_quote() {
        let report = fixture();
        let cm = report.compose_manager_attestation.as_ref().unwrap();
        let quote = dcap_qvl::quote::Quote::parse(&hex::decode(&cm.quote).unwrap()).unwrap();
        let dcap_qvl::quote::Report::TD10(td) = quote.report else { panic!("not TD10") };
        let measured = measured_manager_images(&fixture().info.tcb_info.app_compose);
        assert!(check_compose_manager(cm, &td.report_data, &fixture_nonce(), &measured).unwrap().0 > 0);

        let mut edited = ComposeManagerAttestation {
            actions: cm.actions.clone(),
            actions_hash: cm.actions_hash.clone(),
            nonce: cm.nonce.clone(),
            quote: cm.quote.clone(),
        };
        edited.actions.pop();
        assert!(check_compose_manager(&edited, &td.report_data, &fixture_nonce(), &measured).is_err());
    }

    #[test]
    fn compose_images_must_all_be_pinned_prebuilt_images() {
        let digest = "0".repeat(64);
        let pinned = format!(
            "services:\n  a:\n    image: x/a@sha256:{digest}\n  b:\n    image: ${{B:-x/b@sha256:{digest}}}\n"
        );
        check_compose_images(&pinned, &[]).unwrap();
        // ...but not when the deployment may set that variable.
        assert!(check_compose_images(&pinned, &["B"]).is_err());
        for bad in [
            "services:\n  a:\n    image: nginx:latest\n",
            "services: {a: {image: nginx}}",
            "{\"services\": {\"a\": {\"image\": \"nginx\"}}}",
            "services:\n  a:\n    build: .\n    image: x@sha256:00\n",
            "services:\n  a:\n    image: x/a@sha256:00\n",
            "services:\n  a:\n    command: sleep\n",
            "services: {}",
            "version: '3'",
        ] {
            assert!(check_compose_images(bad, &[]).is_err(), "{bad} should be rejected");
        }
    }

    #[test]
    fn canonical_json_sorts_keys_and_keeps_unicode() {
        let mut out = String::new();
        canonical_json(&serde_json::json!({"b": ["é", 1], "a": {"d": null, "c": "x\"y"}}), &mut out);
        assert_eq!(out, r#"{"a":{"c":"x\"y","d":null},"b":["é",1]}"#);
    }

    #[test]
    fn chat_signature_must_come_from_attested_key() {
        use k256::ecdsa::SigningKey;
        let key = SigningKey::from_slice(&[7u8; 32]).unwrap();
        let address = format!("0x{}", hex::encode(eth_address(key.verifying_key())));
        let request = br#"{"model":"m"}"#;
        let response = br#"{"id":"chat-1"}"#;
        let text = format!(
            "org/model:{}:{}",
            hex::encode(Sha256::digest(request)),
            hex::encode(Sha256::digest(response))
        );
        let mut digest = Keccak256::new();
        digest.update(format!("\x19Ethereum Signed Message:\n{}", text.len()).as_bytes());
        digest.update(text.as_bytes());
        let (sig, recid) = key.sign_prehash_recoverable(&digest.finalize()).unwrap();
        let mut raw = sig.to_bytes().to_vec();
        raw.push(recid.to_byte());
        let mut signed = ChatSignature {
            text,
            signature: format!("0x{}", hex::encode(raw)),
            signing_address: address.clone(),
            signature_kind: Some("provider_tee".into()),
        };

        check_chat_signature(&signed, "org/model", request, response, &address).unwrap();
        // The same signature with v encoded as 27/28 must also verify.
        let mut ethereum_v = hex::decode(signed.signature.trim_start_matches("0x")).unwrap();
        ethereum_v[64] += 27;
        let ethereum_signed = ChatSignature { signature: hex::encode(ethereum_v), ..signed.clone() };
        check_chat_signature(&ethereum_signed, "org/model", request, response, &address).unwrap();
        assert!(check_chat_signature(&signed, "org/other", request, response, &address).is_err());
        assert!(check_chat_signature(&signed, "org/model", b"{}", response, &address).is_err());
        assert!(check_chat_signature(&signed, "org/model", request, b"{}", &address).is_err());
        let other = "0x0000000000000000000000000000000000000001";
        assert!(check_chat_signature(&signed, "org/model", request, response, other).is_err());
        signed.signature_kind = Some("gateway".into());
        assert!(check_chat_signature(&signed, "org/model", request, response, &address).is_err());
    }
}

/// A compose file version the deploy manager brought up, as its log records it.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) struct Deployment {
    pub commit: String,
    pub path: String,
    pub file_sha256: String,
}

/// What the deploy log says is running now.
///
/// A container name belongs to the machine, not to a compose file: NEAR AI's
/// files name their containers explicitly, and the same name is started and
/// stopped across different files as models move between deployments. So a
/// stop by name stops that container whichever file names it, and the log
/// position of each record decides which one is current.
#[derive(Debug, Default)]
pub(crate) struct Running {
    /// Services the log started by name, each with the version that started it
    /// and the log position it was started at.
    pub named: BTreeMap<String, (usize, Deployment)>,
    /// Compose files started whole, by path. `docker compose up` with no
    /// service arguments starts every service the file defines, and the log
    /// does not say which those are, so the services stopped by name since
    /// then are tracked alongside.
    pub whole: BTreeMap<String, WholeFile>,
}

/// A compose file started as a whole, and what has stopped since.
#[derive(Debug, Clone)]
pub(crate) struct WholeFile {
    /// Where in the log this file was started as a whole.
    pub at: usize,
    pub deployment: Deployment,
    pub stopped: BTreeSet<String>,
}

/// Which of a compose file's services are running.
pub(crate) enum Scope<'a> {
    /// Only these, which the log started by name.
    Named(&'a [&'a str]),
    /// Every service the file defines, except these, which a different version
    /// of the same file started later.
    WholeFile(&'a [&'a str]),
}

impl Scope<'_> {
    fn covers(&self, service: &str) -> bool {
        match self {
            Scope::Named(names) => names.contains(&service),
            Scope::WholeFile(superseded) => !superseded.contains(&service),
        }
    }
}

/// What a compose file says a service runs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ModelService {
    pub service: String,
    pub image: String,
    pub weights: String,
    /// The version of the weights, when the deployment fixes one.
    pub revision: Option<String>,
}

/// Replay the deploy log into what is running now, mapping each service to the
/// compose file version that started it. A service keeps running across later
/// deployments of other services, so the newest entry in the log is not
/// necessarily the one that describes a given model's server.
pub(crate) fn running_services(actions: &[serde_json::Value]) -> Running {
    let mut running = Running::default();
    for (at, action) in actions.iter().enumerate() {
        let names: Vec<&str> = action["services"]
            .as_array()
            .map(|names| names.iter().filter_map(serde_json::Value::as_str).collect())
            .unwrap_or_default();
        let path = action["file"].as_str();
        match action["action"].as_str() {
            Some("compose_up") => {
                // Without a file hash there is nothing to check the file
                // against, so anything it starts counts as unreadable rather
                // than as still running its previous definition.
                let deployment = match (action["commit"].as_str(), path, action["file_sha256"].as_str()) {
                    (Some(commit), Some(path), Some(file_sha256)) => Deployment {
                        commit: commit.to_string(),
                        path: path.to_string(),
                        file_sha256: file_sha256.to_string(),
                    },
                    _ => {
                        forget(&mut running, &names, path);
                        continue;
                    }
                };
                if names.is_empty() {
                    // Starts the whole file, superseding whatever earlier
                    // versions of it started, and whatever had been stopped.
                    running.named.retain(|_, (_, started)| started.path != deployment.path);
                    running.whole.insert(
                        deployment.path.clone(),
                        WholeFile { at, deployment, stopped: BTreeSet::new() },
                    );
                } else {
                    for name in names {
                        running.named.insert(name.to_string(), (at, deployment.clone()));
                    }
                }
            }
            Some("compose_down") => forget(&mut running, &names, path),
            // `compose_stage` prepares a deployment without starting it, and
            // `docker_restart` restarts a container as it already is.
            _ => {}
        }
    }
    running
}

/// Stop treating these services as running. With no names, the action covers
/// every service of that compose file.
fn forget(running: &mut Running, names: &[&str], path: Option<&str>) {
    if names.is_empty() {
        if let Some(path) = path {
            running.named.retain(|_, (_, started)| started.path != path);
            running.whole.remove(path);
        }
        return;
    }
    for name in names {
        running.named.remove(*name);
        // That container is stopped, so no whole-file record may keep claiming
        // it, whichever file the stop names.
        for whole in running.whole.values_mut() {
            whole.stopped.insert(name.to_string());
        }
    }
}

/// Every alias copies what it points at, so a small document can expand into
/// an enormous tree. Real compose files are tens of kilobytes with a few dozen
/// aliases; this bounds the product rather than either factor, because that is
/// what the expansion costs.
const EXPANSION_BUDGET: usize = 8 << 20;

fn parse_compose(compose: &str, what: &str) -> Result<serde_yaml_ng::Value, String> {
    // An alias is `*` followed by the anchor's name; an asterisk in a glob, a
    // regular expression or a comment is not one.
    let aliases = compose
        .match_indices('*')
        .filter(|(at, _)| {
            compose[at + 1..]
                .chars()
                .next()
                .is_some_and(|c| c.is_ascii_alphanumeric() || c == '_')
        })
        .count();
    if compose.len() > 1 << 19 || compose.len().saturating_mul(aliases.max(1)) > EXPANSION_BUDGET {
        return Err(format!("{what} would expand to far more than a compose file"));
    }
    let mut doc: serde_yaml_ng::Value =
        serde_yaml_ng::from_str(compose).map_err(|_| format!("{what} is not valid YAML"))?;
    // Model servers are written as `<<: *anchor`, so merge keys have to be
    // applied before a service's own command can be read. An anchor may itself
    // merge another, and one pass copies that inner `<<` into the service as
    // an ordinary key, so repeat until none is left.
    for _ in 0..MERGE_DEPTH {
        doc.apply_merge().map_err(|_| format!("{what} has unusable merge keys"))?;
        if !has_merge_key(&doc) {
            return Ok(doc);
        }
    }
    Err(format!("{what} has unusable merge keys"))
}

/// How many anchors deep a merge may chain. Real files go three deep.
const MERGE_DEPTH: usize = 8;

fn has_merge_key(value: &serde_yaml_ng::Value) -> bool {
    match value {
        serde_yaml_ng::Value::Mapping(mapping) => {
            mapping.contains_key("<<") || mapping.values().any(has_merge_key)
        }
        serde_yaml_ng::Value::Sequence(items) => items.iter().any(has_merge_key),
        serde_yaml_ng::Value::Tagged(tagged) => has_merge_key(&tagged.value),
        _ => false,
    }
}

/// An image is pinned only if it ends in a full digest that the host cannot
/// change. `${VAR:-pinned@sha256:...}` is pinned only while `VAR` cannot be
/// set, which the manifest's `allowed_envs` decides.
fn digest_pinned(image: &str, allowed_envs: &[&str]) -> bool {
    let image = match image.strip_prefix("${") {
        Some(rest) => {
            let Some(inside) = rest.strip_suffix('}') else { return false };
            let Some((name, default)) = inside.split_once(":-") else { return false };
            if name.contains(['{', '}', '$']) || allowed_envs.contains(&name) {
                return false;
            }
            default
        }
        None => image,
    };
    if image.contains('$') {
        return false;
    }
    image
        .rsplit_once("@sha256:")
        .is_some_and(|(repo, digest)| {
            !repo.is_empty() && digest.len() == 64 && digest.chars().all(|c| c.is_ascii_hexdigit())
        })
}

/// Whether `word` names `flag`, allowing for the spellings the serving
/// binaries accept: `_` for `-`, and any abbreviation, which argparse takes by
/// default (so `--model` and `--model-pa` both name `--model-path`). Reading an
/// abbreviation as the flag is the safe direction: it is what the server does.
fn names_flag(word: &str, flag: &str) -> bool {
    let word = word.replace('_', "-");
    word == flag || (word.len() >= 4 && flag.starts_with(&word))
}

/// The values a command-line flag is given, up to the next flag.
fn flag_values<'a>(words: &'a [String], flag: &str) -> Vec<&'a str> {
    let mut values = Vec::new();
    let mut taking = false;
    for word in words {
        if word.starts_with('-') {
            taking = names_flag(word, flag);
        } else if taking {
            values.push(word.as_str());
        }
    }
    values
}

/// Split a shell command line into arguments the way the shell does, so that
/// a quoted value is one argument and cannot be read as a flag of its own.
/// `None` when the line does not parse, which must not be read as "no flags".
fn shell_words(text: &str) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut started = false;
    let mut quote: Option<char> = None;
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        match quote {
            // Inside single quotes everything is literal, backslash included.
            Some('\'') if c == '\'' => quote = None,
            Some('\'') => word.push(c),
            Some('"') if c == '"' => quote = None,
            Some('"') if c == '\\' => match chars.next() {
                // Only these are escapes inside double quotes; anything else
                // keeps the backslash.
                Some(next @ ('"' | '\\' | '$' | '`')) => word.push(next),
                Some(next) => {
                    word.push('\\');
                    word.push(next);
                }
                None => return None,
            },
            Some(_) => word.push(c),
            None if c == '\\' => match chars.next() {
                // A backslash outside quotes makes the next character literal,
                // so it can never open a quoted region.
                Some('\n') => {}
                Some(next) => {
                    word.push(next);
                    started = true;
                }
                None => return None,
            },
            None if c == '\'' || c == '"' => {
                quote = Some(c);
                started = true;
            }
            None if c.is_whitespace() => {
                if started {
                    words.push(std::mem::take(&mut word));
                    started = false;
                }
            }
            None => {
                word.push(c);
                started = true;
            }
        }
    }
    if quote.is_some() {
        return None;
    }
    if started {
        words.push(word);
    }
    Some(words)
}

/// Whether a word's substitutions leave its meaning readable. `${VAR:+text}`
/// expands to fixed text that is right here, so it is readable as long as that
/// text is not itself a flag we depend on; every other form takes its value
/// from a host environment nothing measures.
fn readable_substitutions(word: &str) -> bool {
    let mut rest = word;
    while let Some(at) = rest.find('$') {
        let after = &rest[at + 1..];
        let Some(inside) = after.strip_prefix('{').and_then(|open| open.split_once('}')) else {
            return false;
        };
        let Some((_, literal)) = inside.0.split_once(":+") else {
            return false;
        };
        if literal.contains("--model") || literal.contains("--revision") || literal.contains("--served") {
            return false;
        }
        rest = inside.1;
    }
    true
}

/// A service's command as the arguments the server will see. A sequence entry
/// is already one argument, so it is never split; a plain string is a command
/// line and is split like a shell would. `--flag=value` becomes two words
/// either way.
/// A value read as a list of words, whichever way compose spells it.
fn shell_form(value: Option<&serde_yaml_ng::Value>) -> Option<Vec<String>> {
    match value? {
        serde_yaml_ng::Value::String(text) => shell_words(text),
        serde_yaml_ng::Value::Sequence(items) => {
            items.iter().map(|item| item.as_str().map(str::to_string)).collect()
        }
        _ => None,
    }
}

fn command_words(service: &serde_yaml_ng::Value) -> Option<Vec<String>> {
    let mut words = Vec::new();
    let mut push = |argument: String| match argument
        .strip_prefix('-')
        .and_then(|rest| rest.split_once('='))
    {
        Some((flag, value)) => {
            words.push(format!("-{flag}"));
            words.push(value.to_string());
        }
        None => words.push(argument),
    };
    // An entrypoint like `["/bin/bash", "-lc"]` makes the command a script a
    // shell will split, rather than a list of arguments. `python3 -c` takes a
    // script too, but not one the shell touches.
    let shell_entrypoint = shell_form(service.get("entrypoint")).is_some_and(|words| {
        let shell = words.first().is_some_and(|program| {
            matches!(
                program.rsplit('/').next().unwrap_or_default(),
                "sh" | "bash" | "dash" | "ash" | "zsh" | "busybox"
            )
        });
        shell && words.iter().any(|word| word.starts_with('-') && word.contains('c'))
    });
    for key in ["entrypoint", "command"] {
        match service.get(key) {
            Some(serde_yaml_ng::Value::String(text)) => {
                for argument in shell_words(text)? {
                    push(argument);
                }
            }
            Some(serde_yaml_ng::Value::Sequence(items)) => {
                for item in items {
                    // An entry that is not a string is an argument we cannot
                    // read, not one that is absent.
                    let text = item.as_str()?;
                    // A sequence entry is one argument, unless a shell is going
                    // to split it.
                    if key == "command" && shell_entrypoint {
                        for argument in shell_words(text)? {
                            push(argument);
                        }
                    } else {
                        push(text.to_string());
                    }
                }
            }
            Some(_) => return None,
            None => {}
        }
    }
    if !words.iter().all(|word| readable_substitutions(word)) {
        return None;
    }
    Some(words)
}

/// Weights served from a local Hugging Face cache path name the same repo and
/// snapshot that a repo id and revision would, so read them back that way:
/// `.../models--zai-org--GLM-5.3-Flash/snapshots/84c6a6aa` is that repo at that
/// snapshot. Only the path is attested, never its contents, so this reads no
/// better than the repo id and revision it recovers.
/// A revision only fixes the weights if it names a specific commit. A branch
/// such as `main`, or a variable, is whatever the repo holds at load time.
fn pinned_revision(revision: Option<&str>) -> Option<String> {
    revision
        .filter(|revision| {
            // A full commit id, the only form every real deployment uses. A
            // shorter hex string can also be a branch or tag name, which moves.
            matches!(revision.len(), 40 | 64) && revision.chars().all(|c| c.is_ascii_hexdigit())
        })
        .map(|revision| revision.to_string())
}

fn named_weights(weights: &str, revision: Option<String>) -> (String, Option<String>) {
    let Some((_, tail)) = weights.split_once("models--") else {
        return (weights.to_string(), revision);
    };
    let mut parts = tail.splitn(2, '/');
    let repo = parts.next().unwrap_or_default().replacen("--", "/", 1);
    let snapshot = parts
        .next()
        .and_then(|rest| rest.strip_prefix("snapshots/"))
        .map(|snapshot| snapshot.trim_end_matches('/').to_string())
        .filter(|snapshot| !snapshot.is_empty());
    if !repo.contains('/') {
        return (weights.to_string(), revision);
    }
    (repo, revision.or(snapshot))
}

/// What one compose file says about the services running from it.
#[derive(Debug, Default)]
pub(crate) struct Reading {
    pub services: Vec<ModelService>,
    /// A service that could be answering for this model but whose command
    /// could not be read, so nothing here can be concluded.
    pub unreadable: Option<String>,
}

/// Every service in this compose file that serves `model` and is running now.
///
/// Reading a flag takes its last value, because the serving binaries parse with
/// argparse, where a repeated option overwrites the earlier one. An unpinned
/// image, or weights the host can still change, is an error rather than a miss:
/// a service that answers for this model from something it can swap at will
/// defeats the point of measuring the deployment.
pub(crate) fn find_model_services(
    compose: &str,
    scope: Scope<'_>,
    model: &str,
) -> Result<Reading, String> {
    let doc = parse_compose(compose, "A deployed compose file")?;
    let services = doc
        .get("services")
        .and_then(serde_yaml_ng::Value::as_mapping)
        .ok_or("A deployed compose file lists no services")?;

    let mut reading = Reading::default();
    for (name, service) in services {
        let Some(name) = name.as_str() else { continue };
        if !scope.covers(name) {
            continue;
        }
        // A command we cannot read matters only if this service could be the
        // one serving models at all: a proxy or a log shipper cannot be.
        let Some(words) = command_words(service) else {
            if serves_models(service) {
                reading.unreadable = Some(name.to_string());
            }
            continue;
        };
        // sglang spells it --model-path and vLLM --model, and to argparse the
        // shorter one is just an abbreviation of the longer, so they are one
        // flag with the last value winning. vLLM also takes the model as its
        // first argument instead.
        let flagged = flag_values(&words, "--model-path").last().copied();
        let raw_weights = flagged.or_else(|| positional_model(&words));
        let served = flag_values(&words, "--served-model-name");
        let serves = match (&raw_weights, served.is_empty()) {
            (_, false) => served.contains(&model),
            (Some(weights), true) => *weights == model,
            (None, true) => false,
        };
        if !serves {
            continue;
        }
        let Some(raw_weights) = raw_weights else {
            // It answers for this model but does not say what it loads.
            reading.unreadable = Some(name.to_string());
            continue;
        };

        if service.get("build").is_some() {
            return Err(format!(
                "Service {name} serves {model} from an image built on the host instead of a pinned one"
            ));
        }
        let image = service
            .get("image")
            .and_then(serde_yaml_ng::Value::as_str)
            .ok_or_else(|| format!("Service {name} serves {model} but names no image"))?;
        // A deployed compose file takes its variables from the host's
        // environment, which nothing here measures, so no substitution counts.
        if image.contains('$') || !digest_pinned(image, &[]) {
            return Err(format!("Service {name} serves {model} from an unpinned image: {image}"));
        }

        // Checked before `named_weights`, which would otherwise discard the
        // part of a cache path that carries the substitution.
        if raw_weights.contains('$') {
            return Err(format!(
                "Service {name} serves {model} from {raw_weights}, which the host can repoint"
            ));
        }
        let (weights, revision) = named_weights(
            raw_weights,
            pinned_revision(flag_values(&words, "--revision").last().copied()),
        );
        if weights.starts_with('/') || !weights.contains('/') {
            return Err(format!(
                "Service {name} serves {model} from {weights}, which does not name a fixed model"
            ));
        }
        let revision = pinned_revision(revision.as_deref());
        reading.services.push(ModelService {
            service: name.to_string(),
            image: image.to_string(),
            weights,
            revision,
        });
    }
    Ok(reading)
}

/// Whether a service whose command cannot be read might still be serving
/// models: one that never mentions a model at all, such as a proxy or a log
/// shipper, tells us nothing by being unreadable.
fn serves_models(service: &serde_yaml_ng::Value) -> bool {
    // Only what the container is told to run counts. A label or an
    // environment variable may name a model without serving it.
    ["entrypoint", "command"].iter().any(|key| {
        let text = service
            .get(key)
            .map(|value| serde_yaml_ng::to_string(value).unwrap_or_default())
            .unwrap_or_default();
        text.contains("--served-model-name") || text.contains("--model-path") || text.contains("--model ")
    })
}

/// The model a server takes as its first argument, as vLLM does: the first
/// word that is not a flag or a flag's value, and looks like a repository.
fn positional_model(words: &[String]) -> Option<&str> {
    let mut taking_value = false;
    for word in words {
        if word.starts_with('-') {
            // A flag we do not know may or may not take a value, so stop at the
            // first one rather than guess which words belong to it.
            taking_value = true;
            continue;
        }
        if taking_value {
            return None;
        }
        if word.contains('/') && !word.starts_with('/') {
            return Some(word);
        }
    }
    None
}
