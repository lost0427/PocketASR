/// High-level phases of a transcription job.
enum TranscriptionStage {
  decoding,
  analyzing,
  segmenting,
  loadingModel,
  transcribing,
  finalizing,
}
