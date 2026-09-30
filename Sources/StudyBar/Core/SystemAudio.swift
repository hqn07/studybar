import AVFoundation
import ScreenCaptureKit

/// What the Mac is playing — a Zoom or Teams call, a lecture video — as audio buffers, so a
/// lecture you attend on screen can be recorded without a microphone in the loop.
///
/// ScreenCaptureKit rather than a Core Audio process tap: it works from macOS 13 (a tap needs
/// 14.2) and asks for the same Screen Recording access StudyBar's screen capture already uses.
/// StudyBar's own sound is left out.
final class SystemAudio: NSObject, SCStreamOutput, SCStreamDelegate {
    /// What every buffer arrives as, so the take and Whisper's chunks can be opened up front.
    static let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!

    private var stream: SCStream?
    private var handle: ((AVAudioPCMBuffer) -> Void)?
    private let queue = DispatchQueue(label: "studybar.system-audio")

    func start(_ handle: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw CocoaError(.featureUnsupported) }
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = Int(Self.format.sampleRate)
        cfg.channelCount = Int(Self.format.channelCount)
        // Audio is all that's wanted; the smallest, slowest video a stream allows.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        self.handle = handle
        try await s.startCapture()
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        stream = nil
        handle = nil
        Task { try? await s.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let buf = Self.pcm(sb) else { return }
        handle?(buf)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Diagnostics.warn(.voice, "System audio stopped: \(error.localizedDescription)")
    }

    /// A sample buffer as a PCM buffer in `format` — the take and the chunks were opened in it,
    /// and a file only accepts buffers in its own format. Anything else is dropped.
    static func pcm(_ sb: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let asbd = sb.formatDescription?.audioStreamBasicDescription,
              asbd.mSampleRate == format.sampleRate, asbd.mChannelsPerFrame == format.channelCount,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return nil }
        let frames = AVAudioFrameCount(sb.numSamples)
        guard frames > 0, let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buf.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sb, at: 0, frameCount: Int32(frames), into: buf.mutableAudioBufferList)
        return status == noErr ? buf : nil
    }

    static let denied = "StudyBar can't hear the Mac's sound. Allow it under System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording, then record again."
}
