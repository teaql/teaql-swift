# Optional Linux MP3/MP4 Blob verifier

The `TeaQLBlobReference` product exposes `FfmpegBlobContentVerifier` on Linux.
The host supplies absolute trusted paths to patched `ffprobe`, `ffmpeg` and
`prlimit`, then explicitly constructs the verifier and passes it to
`SQLiteBlobUploadService`. The field's modeled extension policy must separately
allow `mp3` or `mp4`. Import and construction start no decoder or storage work;
`BlobReferenceModule.ready(context:)` checks a verifier that implements
`BlobVerifierReadiness`.

The adapter checks complete MP3 frames or MP4 top-level boxes before forcing
the matching FFmpeg demuxer, validates actual streams and frame counts, rejects
MP4 without a non-attached video track, and fully decodes all streams through
a pipe. Client filenames and URLs never reach FFmpeg. It limits input bytes,
frames, video pixels, concurrent calls and probe output. Each child has 10 CPU
seconds, 512 MiB address space and a 15-second parent wall timeout. The result
is original-byte SHA-256 and actual `audio/mpeg` or `video/mp4`; it is not a
malware scan. Hosts must keep the FFmpeg binaries patched. Other allowed
formats still need their own production verifiers.
