// audiotap: streams live audio to stdout as raw float32, mono, 16 kHz (little endian).
//
//   audiotap system   everything the Mac plays (all apps), via ScreenCaptureKit
//   audiotap mic      the default microphone, shared with any other app using it
//
// Nothing is saved: samples go to stdout only. Status lines go to stderr.
// From Murmury (https://github.com/GianlucaBave/murmury). GPL-3.0.

import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

let sampleRate = 16_000.0

func log(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func emit(_ samples: UnsafeBufferPointer<Float>) {
    guard let base = samples.baseAddress, samples.count > 0 else { return }
    // POSIX write, not FileHandle: when the reader goes away it returns an error instead of
    // raising an Objective-C exception (which crashed the helper on exit).
    if Darwin.write(STDOUT_FILENO, base, samples.count * MemoryLayout<Float>.size) < 0 { exit(0) }
}

// MARK: system audio

final class SystemTap: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "audiotap.system")

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw NSError(domain: "audiotap", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display found"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // Excluding "this process" would also drop audio from anything launched by the same app
        // (macOS groups it under the responsible app, e.g. the terminal), so keep everything.
        config.excludesCurrentProcessAudio = false
        config.sampleRate = Int(sampleRate)
        config.channelCount = 1
        // Video cannot be switched off; keep it as small and slow as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log("audiotap: system audio started (\(Int(sampleRate)) Hz mono)")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, buffer.isValid else { return }
        try? buffer.withAudioBufferList { list, _ in
            guard let first = list.first, let data = first.mData else { return }
            let count = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            emit(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // The display can disappear for a moment (sleep, a full-screen app, a monitor change):
        // reattach instead of stopping.
        log("audiotap: system stream stopped: \(error.localizedDescription); reattaching")
        self.stream = nil
        Task { await self.startWithRetry() }
    }

    func startWithRetry() async {
        while true {
            do {
                try await start()
                return
            } catch {
                log("audiotap: cannot attach yet: \(error.localizedDescription); retrying in 1 s")
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
}

// MARK: microphone

final class MicTap {
    private let engine = AVAudioEngine()

    func start() throws {
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "audiotap", code: 3, userInfo: [NSLocalizedDescriptionKey: "no converter"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { buffer, _ in
            let ratio = sampleRate / inFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            if let channel = out.floatChannelData?[0] {
                emit(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
        }
        try engine.start()
        log("audiotap: microphone started (\(Int(sampleRate)) Hz mono, from \(Int(inFormat.sampleRate)) Hz)")
    }
}

// MARK: main

let source = CommandLine.arguments.dropFirst().first ?? "system"
signal(SIGPIPE, SIG_IGN)

switch source {
case "system":
    let tap = SystemTap()
    Task {
        do { try await tap.start() } catch {
            let message = error.localizedDescription
            log("audiotap: cannot start system audio: \(message)")
            if (error as NSError).code == -3801 || message.contains("TCC") {  // permission refused: no point retrying
                log("audiotap: allow it in System Settings > Privacy & Security > Screen & System Audio Recording")
                exit(1)
            }
            await tap.startWithRetry()
        }
    }
    withExtendedLifetime(tap) { RunLoop.main.run() }
case "mic":
    let tap = MicTap()
    do { try tap.start() } catch {
        log("audiotap: cannot start microphone: \(error.localizedDescription)")
        exit(1)
    }
    withExtendedLifetime(tap) { RunLoop.main.run() }
default:
    log("usage: audiotap system|mic")
    exit(64)
}
