export const RECORD_FRAME_RATE = 0.5;
export const ENCODING_FRAME_RATE = 30;
export const ENCODING_FRAME_INTERVAL = 1 / ENCODING_FRAME_RATE;

export const AUDIO_CHUNK_DURATION = 30; // seconds
export const AUDIO_SAMPLE_RATE = 16000; // Hz, required by whisper.cpp
export const TRANSCRIPTION_CHECK_INTERVAL = 10000; // ms
export const AUDIO_CLEANUP_INTERVAL = 60000; // ms
export const RETENTION_DAYS = 14;
