//! Pattern-based scrubbing of direct identifiers before text reaches the notes model.
//! Ported verbatim from desktop `confidential/redact.rs` (tests included).
//!
//! This is deliberately conservative: it removes things that are reliably
//! identifiable by shape (email addresses, phone numbers, government ID and
//! card numbers, URLs).  Names cannot be detected by pattern; the notes model
//! is instructed to refer to people by role instead (see
//! `prompt::privacy_rules`).
//!
//! The user chooses which categories to scrub when generating notes; every
//! category is on unless explicitly turned off.

#![allow(dead_code)] // count_pii / scrub_pii are kept from desktop for parity and tests.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock as Lazy;

/// Which identifier categories to remove before text leaves the app.
/// Missing fields deserialize as `true`, so an older or partial request
/// scrubs everything.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, uniffi::Record)]
#[serde(default, rename_all = "camelCase")]
pub struct ScrubOptions {
    #[uniffi(default = true)]
    pub emails: bool,
    #[uniffi(default = true)]
    pub phones: bool,
    #[uniffi(default = true)]
    pub urls: bool,
    /// Government ID, payment card and long account-style numbers.
    #[uniffi(default = true)]
    pub numbers: bool,
    /// Names cannot be matched by pattern; this controls the notes prompt.
    #[uniffi(default = true)]
    pub names: bool,
}

impl Default for ScrubOptions {
    fn default() -> Self {
        Self::all()
    }
}

impl ScrubOptions {
    pub const fn all() -> Self {
        Self { emails: true, phones: true, urls: true, numbers: true, names: true }
    }

    pub const fn none() -> Self {
        Self { emails: false, phones: false, urls: false, numbers: false, names: false }
    }

    /// Whether any pattern-based category is on (i.e. placeholders may appear).
    pub fn any_pattern(&self) -> bool {
        self.emails || self.phones || self.urls || self.numbers
    }

    fn allows(&self, kind: Kind) -> bool {
        match kind {
            Kind::Email => self.emails,
            Kind::Phone => self.phones,
            Kind::Url => self.urls,
            Kind::Number => self.numbers,
        }
    }
}

#[derive(Clone, Copy)]
enum Kind {
    Email,
    Phone,
    Url,
    Number,
}

struct Rule {
    kind: Kind,
    pattern: Regex,
    placeholder: &'static str,
}

static RULES: Lazy<Vec<Rule>> = Lazy::new(|| {
    let rule = |kind: Kind, pattern: &str, placeholder: &'static str| Rule {
        kind,
        pattern: Regex::new(pattern).expect("static redaction regex must compile"),
        placeholder,
    };
    vec![
        rule(
            Kind::Email,
            r"(?i)\b[a-z0-9._%+\-]+@[a-z0-9.\-]+\.[a-z]{2,}\b",
            "[EMAIL]",
        ),
        rule(Kind::Url, r#"(?i)\b(?:https?://|www\.)[^\s<>"]+"#, "[URL]"),
        // US social security numbers.
        rule(Kind::Number, r"\b\d{3}[\s-]\d{2}[\s-]\d{4}\b", "[ID]"),
        // Payment card numbers (13-19 digits with optional separators).
        rule(Kind::Number, r"\b\d(?:[\s-]?\d){12,18}\b", "[CARD]"),
        // Phone numbers: optional country code, then 7-12 digits with common separators.
        rule(
            Kind::Phone,
            r"(?:\+?\d{1,3}[\s\-.]?)?(?:\(\d{2,4}\)|\d{2,4})[\s\-.]?\d{3,4}[\s\-.]?\d{3,4}\b",
            "[PHONE]",
        ),
        rule(Kind::Phone, r"\b\d{3}[\s.-]\d{4}\b", "[PHONE]"),
        // Long bare digit runs (account numbers, MRNs).
        rule(Kind::Number, r"\b\d{7,}\b", "[NUMBER]"),
    ]
});

/// How many identifiers of each pattern category `text` contains. Counts only,
/// so the UI can show what scrubbing will catch without seeing any text.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetectedCounts {
    pub emails: usize,
    pub phones: usize,
    pub urls: usize,
    pub numbers: usize,
}

/// Count identifiers the same way `scrub_pii` removes them: rules run in order
/// on progressively scrubbed text, so one span is never counted twice.
pub fn count_pii(text: &str) -> DetectedCounts {
    let mut counts = DetectedCounts::default();
    let mut out = text.to_string();
    for rule in RULES.iter() {
        let found = rule.pattern.find_iter(&out).count();
        if found == 0 {
            continue;
        }
        match rule.kind {
            Kind::Email => counts.emails += found,
            Kind::Phone => counts.phones += found,
            Kind::Url => counts.urls += found,
            Kind::Number => counts.numbers += found,
        }
        out = rule.pattern.replace_all(&out, rule.placeholder).into_owned();
    }
    counts
}

/// Replace every category of direct identifier in `text` with bracketed placeholders.
pub fn scrub_pii(text: &str) -> String {
    scrub_pii_with(text, &ScrubOptions::all())
}

/// Replace the selected categories of direct identifiers in `text`.
pub fn scrub_pii_with(text: &str, options: &ScrubOptions) -> String {
    let mut out = text.to_string();
    for rule in RULES.iter().filter(|rule| options.allows(rule.kind)) {
        out = rule
            .pattern
            .replace_all(&out, rule.placeholder)
            .into_owned();
    }
    out
}

#[cfg(test)]
mod tests {
    use super::{count_pii, scrub_pii, scrub_pii_with, DetectedCounts, ScrubOptions};

    #[test]
    fn counts_each_category_once() {
        let counts = count_pii("mail a@b.co or c@d.org, call 555-123-4567, see www.x.com, card 4111 1111 1111 1111");
        assert_eq!(counts, DetectedCounts { emails: 2, phones: 1, urls: 1, numbers: 1 });
    }

    #[test]
    fn scrubs_email_and_url() {
        let s = scrub_pii("write to jane.doe@example.org or see https://example.org/x?y=1 now");
        assert_eq!(s, "write to [EMAIL] or see [URL] now");
    }

    #[test]
    fn scrubs_phone_variants() {
        for input in [
            "call 555-123-4567",
            "call (555) 123-4567",
            "call +1 555 123 4567",
            "call 0412 345 678",
            "call 555-1234",
            "call 555 1234",
        ] {
            let s = scrub_pii(input);
            assert!(s.contains("[PHONE]"), "{input} -> {s}");
            assert!(
                s.chars().filter(|c| c.is_ascii_digit()).count() <= 3,
                "{input} -> {s}"
            );
        }
    }

    #[test]
    fn scrubs_ssn_and_card() {
        assert_eq!(scrub_pii("ssn 123-45-6789"), "ssn [ID]");
        assert_eq!(scrub_pii("ssn 123 45 6789"), "ssn [ID]");
        assert_eq!(scrub_pii("card 4111 1111 1111 1111 now"), "card [CARD] now");
        assert_eq!(scrub_pii("card 4111 1111 1111 1111"), "card [CARD]");
    }

    #[test]
    fn leaves_ordinary_text_and_small_numbers_alone() {
        let s = "I slept 6 hours and my mood was 4 out of 10 on Tuesday";
        assert_eq!(scrub_pii(s), s);
    }

    #[test]
    fn scrubs_only_selected_categories() {
        let input = "mail jane@example.org, call 555-123-4567, see www.example.org, ssn 123-45-6789";
        let only_email = ScrubOptions { emails: true, ..ScrubOptions::none() };
        assert_eq!(
            scrub_pii_with(input, &only_email),
            "mail [EMAIL], call 555-123-4567, see www.example.org, ssn 123-45-6789"
        );
        let only_phone = ScrubOptions { phones: true, ..ScrubOptions::none() };
        assert_eq!(
            scrub_pii_with(input, &only_phone),
            "mail jane@example.org, call [PHONE], see www.example.org, ssn 123-45-6789"
        );
        assert_eq!(scrub_pii_with(input, &ScrubOptions::none()), input);
        assert_eq!(scrub_pii_with(input, &ScrubOptions::all()), scrub_pii(input));
    }

    #[test]
    fn scrubs_only_urls_or_only_numbers() {
        let input = "see https://example.org/a, ssn 123-45-6789, card 4111 1111 1111 1111, acct 12345678, call 555-123-4567";
        let only_urls = ScrubOptions { urls: true, ..ScrubOptions::none() };
        assert_eq!(
            scrub_pii_with(input, &only_urls),
            "see [URL] ssn 123-45-6789, card 4111 1111 1111 1111, acct 12345678, call 555-123-4567"
        );
        let only_numbers = ScrubOptions { numbers: true, ..ScrubOptions::none() };
        assert_eq!(
            scrub_pii_with(input, &only_numbers),
            "see https://example.org/a, ssn [ID], card [CARD], acct [NUMBER], call 555-123-4567"
        );
    }

    #[test]
    fn bare_digit_phone_is_still_scrubbed_as_a_number_when_phones_are_kept() {
        // Undelimited phone numbers are indistinguishable from account numbers;
        // keeping phones must not un-scrub them when numbers are selected.
        let options = ScrubOptions { phones: false, ..ScrubOptions::all() };
        assert_eq!(scrub_pii_with("call 5551234567", &options), "call [NUMBER]");
    }

    #[test]
    fn missing_option_fields_default_to_scrubbing() {
        let options: ScrubOptions = serde_json::from_str(r#"{"phones": false}"#).unwrap();
        assert_eq!(options, ScrubOptions { phones: false, ..ScrubOptions::all() });
    }
}
