//! In-memory transcript store (port of desktop `confidential/store.rs`).
//!
//! One store per `Session` rather than a process global. Segment text lives in
//! `mlock`ed pages that are zeroed on drop; nothing here touches the filesystem.
//! Text leaves only through [`TranscriptStore::transcript_for_llm`], scrubbed.

use crate::redact::{scrub_pii_with, ScrubOptions};
use crate::secure::{wipe_string, LockedBytes};

/// A freshly transcribed segment on its way into the store. The text buffer
/// is zeroed when this is dropped (immediately after it is copied into locked
/// storage).
pub struct StoredSegment {
    pub sequence_id: u64,
    pub text: String,
    pub audio_start_ms: u64,
    pub audio_end_ms: u64,
}

impl Drop for StoredSegment {
    fn drop(&mut self) {
        wipe_string(&mut self.text);
    }
}

struct LockedText(LockedBytes);
impl std::ops::Deref for LockedText {
    type Target = str;
    fn deref(&self) -> &str {
        std::str::from_utf8(self.0.as_slice()).expect("text is UTF-8")
    }
}

struct ProtectedSegment {
    sequence_id: u64,
    text: LockedText,
    audio_start_ms: u64,
    audio_end_ms: u64,
}

/// Counts and timings that are safe to show in the UI.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StoreStats {
    pub segments: u32,
    pub speech_ms: u64,
}

#[derive(Default)]
pub struct TranscriptStore {
    segments: Vec<ProtectedSegment>,
    finalized: bool,
}

#[cfg_attr(not(test), allow(dead_code))]
impl TranscriptStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// Record or replace (by sequence id) a segment. Fails if the text cannot
    /// be placed in locked memory; the caller must surface that.
    pub fn record_segment(&mut self, segment: StoredSegment) -> Result<StoreStats, String> {
        if self.finalized {
            return Err("transcript is finalized".into());
        }
        if segment.text.trim().is_empty() {
            return Ok(self.stats());
        }
        let protected = ProtectedSegment {
            sequence_id: segment.sequence_id,
            text: LockedText(LockedBytes::new(segment.text.as_bytes())?),
            audio_start_ms: segment.audio_start_ms,
            audio_end_ms: segment.audio_end_ms,
        };
        drop(segment);
        match self.segments.iter_mut().find(|s| s.sequence_id == protected.sequence_id) {
            Some(existing) => *existing = protected,
            None => self.segments.push(protected),
        }
        Ok(self.stats())
    }

    pub fn stats(&self) -> StoreStats {
        StoreStats {
            segments: self.segments.len() as u32,
            speech_ms: self
                .segments
                .iter()
                .map(|s| s.audio_end_ms.saturating_sub(s.audio_start_ms))
                .sum(),
        }
    }

    pub fn word_count(&self) -> usize {
        self.segments.iter().map(|s| s.text.split_whitespace().count()).sum()
    }

    /// Sort by audio time and refuse further segments.
    pub fn finalize(&mut self) -> StoreStats {
        self.segments.sort_by(|a, b| {
            a.audio_start_ms
                .cmp(&b.audio_start_ms)
                .then(a.sequence_id.cmp(&b.sequence_id))
        });
        self.finalized = true;
        self.stats()
    }

    pub fn is_finalized(&self) -> bool {
        self.finalized
    }

    pub fn is_empty(&self) -> bool {
        self.segments.is_empty()
    }

    /// Join before scrubbing so identifiers split across VAD boundaries are
    /// removed. The unscrubbed join is wiped before returning. The caller owns
    /// (and must wipe) the scrubbed result.
    pub fn transcript_for_llm(&self, options: &ScrubOptions) -> Option<String> {
        if !self.finalized || self.segments.is_empty() {
            return None;
        }
        let mut text = self
            .segments
            .iter()
            .map(|s| s.text.trim())
            .collect::<Vec<_>>()
            .join(" ");
        let scrubbed = scrub_pii_with(&text, options);
        wipe_string(&mut text);
        Some(scrubbed)
    }

    /// Forget everything. Locked pages are zeroed as segments drop.
    pub fn discard(&mut self) {
        self.segments.clear();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seg(id: u64, text: &str, start_ms: u64) -> StoredSegment {
        StoredSegment {
            sequence_id: id,
            text: text.to_string(),
            audio_start_ms: start_ms,
            audio_end_ms: start_ms + 2000,
        }
    }

    #[test]
    fn segments_flow_to_finalized_and_are_discardable() {
        let mut store = TranscriptStore::new();
        store.record_segment(seg(2, "second line", 5000)).unwrap();
        store.record_segment(seg(1, "hello there", 0)).unwrap();
        assert_eq!(store.stats(), StoreStats { segments: 2, speech_ms: 4000 });
        assert_eq!(store.word_count(), 4);
        assert!(store.transcript_for_llm(&ScrubOptions::all()).is_none(), "not before finalize");
        store.finalize();
        assert!(store.record_segment(seg(3, "late", 9000)).is_err());
        assert_eq!(
            store.transcript_for_llm(&ScrubOptions::all()).unwrap(),
            "hello there second line"
        );
        store.discard();
        assert!(store.is_empty());
        assert!(store.transcript_for_llm(&ScrubOptions::all()).is_none());
    }

    #[test]
    fn record_segment_replaces_by_sequence_id() {
        let mut store = TranscriptStore::new();
        store.record_segment(seg(7, "draft", 1000)).unwrap();
        store.record_segment(seg(7, "final words", 1000)).unwrap();
        assert_eq!(store.stats().segments, 1);
        assert_eq!(store.word_count(), 2);
    }

    #[test]
    fn empty_segments_are_ignored() {
        let mut store = TranscriptStore::new();
        store.record_segment(seg(1, "   ", 0)).unwrap();
        assert!(store.is_empty());
    }

    #[test]
    fn llm_text_is_scrubbed_including_split_phone() {
        let mut store = TranscriptStore::new();
        store.record_segment(seg(1, "call me at 555 123", 0)).unwrap();
        store.record_segment(seg(2, "4567 after six", 2000)).unwrap();
        store.finalize();
        assert_eq!(
            store.transcript_for_llm(&ScrubOptions::all()).unwrap(),
            "call me at [PHONE] after six"
        );
        assert_eq!(
            store.transcript_for_llm(&ScrubOptions::none()).unwrap(),
            "call me at 555 123 4567 after six"
        );
    }

    #[test]
    fn incoming_segment_text_is_zeroed_on_drop() {
        // StoredSegment wipes its String buffer before the allocator frees it:
        // move the String out after Drop-equivalent wiping and inspect it.
        let mut segment = seg(1, "CANARY-incoming-segment", 0);
        let len = segment.text.len();
        let p = segment.text.as_ptr();
        // Same code path Drop runs; inspect while the allocation is still alive.
        wipe_string(&mut segment.text);
        let bytes = unsafe { std::slice::from_raw_parts(p, len) };
        assert!(bytes.iter().all(|b| *b == 0));
    }
}
