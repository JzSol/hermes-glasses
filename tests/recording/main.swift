//
// Standalone tests for ConversationRecorder and TranscriptionService's pure
// parts. No XCTest target, so build via swiftc:
//   xcrun swiftc \
//     HermesGlasses/Services/Social/ConversationRecorder.swift \
//     HermesGlasses/Services/Social/TranscriptionService.swift \
//     tests/recording/main.swift -o /tmp/recording-tests && /tmp/recording-tests
//
// NOTE: this file ends in print(...) then exit(...). New assertions go
// ABOVE those two lines or they never run.
//
import Foundation

var failures = 0
func expectEqual<T: Equatable>(_ got: T, _ want: T, _ label: String) {
    if got == want { print("PASS \(label)") }
    else { failures += 1; print("FAIL \(label)\n  got:  \(got)\n  want: \(want)") }
}
func expectTrue(_ got: Bool, _ label: String) { expectEqual(got, true, label) }

let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("recording-tests-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }

/// 16-bit little-endian read out of a WAV header.
func le32(_ data: Data, _ offset: Int) -> UInt32 {
    data[offset..<(offset + 4)].reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
}
func ascii(_ data: Data, _ offset: Int, _ count: Int) -> String {
    String(decoding: data[offset..<(offset + count)], as: UTF8.self)
}

// MARK: - Header shape

let emptyHeader = ConversationRecorder.header(dataBytes: 0)
expectEqual(emptyHeader.count, 44, "a PCM WAV header is 44 bytes")
expectEqual(ascii(emptyHeader, 0, 4), "RIFF", "starts with RIFF")
expectEqual(ascii(emptyHeader, 8, 4), "WAVE", "declares WAVE")
expectEqual(ascii(emptyHeader, 36, 4), "data", "data chunk follows fmt")
expectEqual(le32(emptyHeader, 24), UInt32(ConversationRecorder.sampleRate),
            "sample rate matches what the audio manager converts to")

let sized = ConversationRecorder.header(dataBytes: 1000)
expectEqual(le32(sized, 40), 1000, "data chunk size is the sample byte count")
expectEqual(le32(sized, 4), UInt32(36 + 1000), "RIFF size covers header + samples")

// MARK: - Writing

let recorder = ConversationRecorder()
let url = root.appendingPathComponent("a.wav")
expectTrue(recorder.start(url: url), "start opens a file")

// 100 buffers of 512 samples: PCM16 mono, so 1024 bytes each.
let buffer = Data(repeating: 0x11, count: 1024)
for _ in 0..<100 { recorder.append(buffer) }

let finished = recorder.finish()
expectTrue(finished != nil, "finish returns the recording")

let written = try! Data(contentsOf: url)
expectEqual(written.count, 44 + 102_400, "every appended buffer reached the file")
expectEqual(le32(written, 40), 102_400,
            "the header's size is patched on close, not left at zero")
expectEqual(le32(written, 4), UInt32(36 + 102_400), "RIFF size is patched too")

// MARK: - Nothing recorded

let silent = ConversationRecorder()
let silentURL = root.appendingPathComponent("silent.wav")
expectTrue(silent.start(url: silentURL), "start opens a file for a silent take")
expectTrue(silent.finish() == nil, "a recording with no audio returns nil")
expectTrue(!FileManager.default.fileExists(atPath: silentURL.path),
           "an empty recording is deleted, not left as a 44-byte stub")

// MARK: - Discard

let cancelled = ConversationRecorder()
let cancelledURL = root.appendingPathComponent("cancelled.wav")
_ = cancelled.start(url: cancelledURL)
cancelled.append(buffer)
cancelled.discard()
expectTrue(!FileManager.default.fileExists(atPath: cancelledURL.path),
           "discard removes the file")

// MARK: - Crash repair

// What a crash mid-capture leaves: samples on disk, header still saying zero.
let crashed = root.appendingPathComponent("crashed.wav")
var crashedData = ConversationRecorder.header(dataBytes: 0)
crashedData.append(Data(repeating: 0x22, count: 4096))
try! crashedData.write(to: crashed)

expectTrue(ConversationRecorder.repairIfNeeded(at: crashed),
           "a truncated recording is repairable")
let repaired = try! Data(contentsOf: crashed)
expectEqual(le32(repaired, 40), 4096, "repair writes the real data size")
expectEqual(le32(repaired, 4), UInt32(36 + 4096), "repair writes the real RIFF size")

// A header-only file has no audio to recover.
let stub = root.appendingPathComponent("stub.wav")
try! ConversationRecorder.header(dataBytes: 0).write(to: stub)
expectTrue(!ConversationRecorder.repairIfNeeded(at: stub),
           "a header-only file is not claimed as usable audio")
expectTrue(!ConversationRecorder.repairIfNeeded(at: root.appendingPathComponent("nope.wav")),
           "a missing file is not claimed as usable audio")

// MARK: - Transcript segmentation

expectEqual(
    TranscriptionService.segment("Hi there. What do you do? I work in radiology!"),
    ["Hi there.", "What do you do?", "I work in radiology!"],
    "sentences split on terminal punctuation")
expectEqual(
    TranscriptionService.segment("no punctuation at all"),
    ["no punctuation at all"],
    "an unpunctuated transcription is one line, not zero")
expectEqual(TranscriptionService.segment(""), [], "empty text yields no lines")
expectEqual(TranscriptionService.segment("   \n  "), [],
            "whitespace-only text yields no lines")
// The ellipsis stays whole. It still ends a line, because a trailing "..."
// is where a speaker did stop - what matters is that no line is a bare ".".
expectEqual(
    TranscriptionService.segment("Done. And then... nothing"),
    ["Done.", "And then...", "nothing"],
    "an ellipsis is never split into lines that are a single full stop")
expectEqual(
    TranscriptionService.segment("Really?! Yes."),
    ["Really?!", "Yes."],
    "stacked terminators stay with their sentence")
expectEqual(
    TranscriptionService.segment("Ends mid-sentence and then"),
    ["Ends mid-sentence and then"],
    "a trailing fragment is kept, not dropped")

// MARK: - Reported duration

// `finish()` keeps bytesWritten (the header patch needs it), so a duration
// read off the byte count alone reported the PREVIOUS take's length for the
// whole gap between recordings.
let timed = ConversationRecorder()
let timedURL = root.appendingPathComponent("timed.wav")
expectEqual(timed.recordedSeconds, 0, "nothing recorded yet is zero seconds")
expectTrue(timed.start(url: timedURL), "start opens a file for the timed take")
// One second: PCM16 mono, so two bytes a frame.
timed.append(Data(count: ConversationRecorder.sampleRate * 2))
expectEqual(timed.recordedSeconds, 1, "a second of audio reads as one second")
expectTrue(timed.finish() != nil, "the timed take finishes")
expectEqual(timed.recordedSeconds, 0,
            "duration goes back to zero when the recording ends")

print(failures == 0 ? "\nAll recording tests passed" : "\n\(failures) failure(s)")
exit(failures == 0 ? 0 : 1)
