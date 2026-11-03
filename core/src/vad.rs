//! Lightweight energy VAD that cuts 16 kHz mono audio into utterances.
//!
//! Deliberately simple for the spike (no ONNX / silero): 30 ms frames, an
//! adaptive noise floor, a speech threshold above it, a hangover before an
//! utterance closes, a short pre-roll, and a hard cap on utterance length.

pub const SAMPLE_RATE: usize = 16_000;
const FRAME: usize = SAMPLE_RATE * 30 / 1000; // 480 samples
const HANGOVER_FRAMES: usize = 25; // 750 ms of silence closes an utterance
const PREROLL_FRAMES: usize = 10; // 300 ms kept before speech onset
const MIN_SPEECH_FRAMES: usize = 8; // utterances with < 240 ms of speech are dropped
const MAX_UTTERANCE: usize = SAMPLE_RATE * 28; // whisper window is 30 s
const ABS_FLOOR: f32 = 0.004; // ~ -48 dBFS; never call quieter frames speech
const NOISE_RATIO: f32 = 3.0;

/// A finished utterance. `start_sample` counts from the start of the session.
pub struct Utterance {
    pub samples: Vec<f32>,
    pub start_sample: u64,
}

impl Utterance {
    pub fn end_sample(&self) -> u64 {
        self.start_sample + self.samples.len() as u64
    }
}

#[derive(Default)]
pub struct Output {
    pub utterances: Vec<Utterance>,
    /// Samples judged silence and dropped (no longer pending).
    pub discarded: u64,
}

pub struct EnergyVad {
    partial: Vec<f32>,
    /// Samples consumed into whole frames so far.
    position: u64,
    noise: f32,
    preroll: std::collections::VecDeque<Vec<f32>>,
    current: Vec<f32>,
    current_start: u64,
    in_speech: bool,
    silent_run: usize,
    speech_frames: usize,
}

impl Default for EnergyVad {
    fn default() -> Self {
        Self {
            partial: Vec::with_capacity(FRAME),
            position: 0,
            noise: ABS_FLOOR,
            preroll: Default::default(),
            current: Vec::new(),
            current_start: 0,
            in_speech: false,
            silent_run: 0,
            speech_frames: 0,
        }
    }
}

fn rms(frame: &[f32]) -> f32 {
    (frame.iter().map(|s| s * s).sum::<f32>() / frame.len() as f32).sqrt()
}

impl EnergyVad {
    pub fn push(&mut self, mut samples: &[f32]) -> Output {
        let mut out = Output::default();
        while !samples.is_empty() {
            let take = (FRAME - self.partial.len()).min(samples.len());
            self.partial.extend_from_slice(&samples[..take]);
            samples = &samples[take..];
            if self.partial.len() == FRAME {
                let frame = std::mem::replace(&mut self.partial, Vec::with_capacity(FRAME));
                self.frame(frame, &mut out);
            }
        }
        out
    }

    /// End of stream: close any open utterance and drop the remainder.
    pub fn flush(&mut self) -> Output {
        let mut out = Output::default();
        if self.in_speech {
            let tail = std::mem::take(&mut self.partial);
            self.current.extend_from_slice(&tail);
            self.close(&mut out);
        } else {
            out.discarded += self.partial.len() as u64;
            self.partial.clear();
        }
        out.discarded += self.preroll.drain(..).map(|f| f.len() as u64).sum::<u64>();
        out
    }

    fn frame(&mut self, frame: Vec<f32>, out: &mut Output) {
        let level = rms(&frame);
        let threshold = (self.noise * NOISE_RATIO).max(ABS_FLOOR);
        let speech = level > threshold;
        if !speech {
            // Track the floor down fast, up slowly.
            self.noise = if level < self.noise { level.max(1e-5) } else { self.noise * 0.995 + level * 0.005 };
        }
        let frame_start = self.position;
        self.position += frame.len() as u64;

        if self.in_speech {
            self.current.extend_from_slice(&frame);
            if speech {
                self.silent_run = 0;
                self.speech_frames += 1;
            } else {
                self.silent_run += 1;
            }
            if self.silent_run >= HANGOVER_FRAMES || self.current.len() + FRAME > MAX_UTTERANCE {
                self.close(out);
            }
        } else if speech {
            self.in_speech = true;
            self.silent_run = 0;
            self.speech_frames = 1;
            let preroll: usize = self.preroll.iter().map(Vec::len).sum();
            self.current_start = frame_start - preroll as u64;
            self.current.clear();
            for f in self.preroll.drain(..) {
                self.current.extend_from_slice(&f);
            }
            self.current.extend_from_slice(&frame);
        } else {
            self.preroll.push_back(frame);
            if self.preroll.len() > PREROLL_FRAMES {
                let dropped = self.preroll.pop_front().unwrap();
                out.discarded += dropped.len() as u64;
            }
        }
    }

    fn close(&mut self, out: &mut Output) {
        let samples = std::mem::take(&mut self.current);
        if self.speech_frames >= MIN_SPEECH_FRAMES {
            out.utterances.push(Utterance { samples, start_sample: self.current_start });
        } else {
            out.discarded += samples.len() as u64;
        }
        self.in_speech = false;
        self.silent_run = 0;
        self.speech_frames = 0;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tone(ms: usize, amp: f32) -> Vec<f32> {
        (0..SAMPLE_RATE * ms / 1000)
            .map(|i| amp * (i as f32 * 2.0 * std::f32::consts::PI * 220.0 / SAMPLE_RATE as f32).sin())
            .collect()
    }

    fn silence(ms: usize) -> Vec<f32> {
        vec![0.0005; SAMPLE_RATE * ms / 1000]
    }

    #[test]
    fn splits_speech_on_silence_and_accounts_for_every_sample() {
        let mut vad = EnergyVad::default();
        let mut audio = silence(1000);
        audio.extend(tone(1500, 0.3));
        audio.extend(silence(1500));
        audio.extend(tone(800, 0.3));
        audio.extend(silence(200));
        let total = audio.len() as u64;
        let mut utterances = Vec::new();
        let mut discarded = 0;
        // Odd chunk size to exercise frame reassembly.
        for chunk in audio.chunks(1234) {
            let out = vad.push(chunk);
            discarded += out.discarded;
            utterances.extend(out.utterances);
        }
        let out = vad.flush();
        discarded += out.discarded;
        utterances.extend(out.utterances);

        assert_eq!(utterances.len(), 2);
        let first = &utterances[0];
        assert!(first.start_sample <= 16_000 && first.start_sample >= 16_000 - 4_800 - FRAME as u64);
        let kept: u64 = utterances.iter().map(|u| u.samples.len() as u64).sum();
        assert_eq!(kept + discarded, total, "every sample is either kept or discarded");
    }

    #[test]
    fn long_speech_is_capped() {
        let mut vad = EnergyVad::default();
        let out = vad.push(&tone(31_000, 0.3));
        assert_eq!(out.utterances.len(), 1);
        assert!(out.utterances[0].samples.len() <= MAX_UTTERANCE);
        assert_eq!(vad.flush().utterances.len(), 1);
    }

    #[test]
    fn clicks_are_dropped() {
        let mut vad = EnergyVad::default();
        let mut audio = silence(500);
        audio.extend(tone(60, 0.5));
        audio.extend(silence(1500));
        let mut out = vad.push(&audio);
        out.utterances.extend(vad.flush().utterances);
        assert!(out.utterances.is_empty());
    }
}
