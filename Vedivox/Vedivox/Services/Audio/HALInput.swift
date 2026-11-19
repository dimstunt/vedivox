import AVFoundation
import CoreAudio

/// One input device opened straight on the HAL: an IOProc on the device
/// itself, with no AVAudioEngine in between. The engine's
/// input node is born on a private aggregate of the system default devices
/// and stays tied to them even when bound to another device: opening it sent
/// AirPods that were the default input into headset mode, and a mic it was
/// bound to gave no frames while the default sat on them (2026-11-19: a
/// 7.2 s hole in a recording from a USB mic). This touches the one device it
/// is given.
final class HALInput {
    enum Failure: Error, LocalizedError {
        case noInput
        case format(String)
        case hal(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noInput: "The device has no input stream"
            case .format(let what): "Unsupported input format: \(what)"
            case .hal(let call, let status): "\(call) failed: \(status) '\(AudioObjectID.fourCC(UInt32(bitPattern: status)))'"
            }
        }
    }

    /// What the IO thread and the queue share. `handler` is touched on the
    /// queue only; the rest on the IO thread only, and read once IO stopped.
    private final class Relay: @unchecked Sendable {
        var handler: AVAudioNodeTapBlock?
        var nextSampleTime: Double?
        var skippedFrames = 0
        var skips = 0
    }

    let deviceID: AudioDeviceID
    /// What `start` hands out: Float32, deinterleaved, at the device's rate —
    /// the shape the engine's input node gave, which the rest of the capture
    /// and the track's file are built around.
    let format: AVAudioFormat
    private var procID: AudioDeviceIOProcID?
    /// Where the handler runs: in order, off the IO thread. The IO cycle only
    /// copies its input out, so a slow disk does not make the device skip
    /// cycles — the engine's tap was decoupled the same way.
    private let queue = DispatchQueue(label: "HALInput.tap", qos: .userInitiated)
    private let relay = Relay()

    init(deviceID: AudioDeviceID) throws {
        let channels = deviceID.readInputChannelCount()
        guard channels > 0, let stream = deviceID.readInputStreamFormat() else { throw Failure.noInput }
        // An IOProc gets the stream's virtual format as it is: anything but
        // packed native Float32 would go into the track as noise.
        // shortcut: such a device is refused, not converted — every input
        // seen so far is Float32; convert here when one is not.
        guard stream.mFormatID == kAudioFormatLinearPCM,
              stream.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              stream.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              stream.mBitsPerChannel == 32, stream.mSampleRate > 0,
              let format = AudioConverter.float32Format(channels: channels, sampleRate: stream.mSampleRate)
        else {
            throw Failure.format("\(stream.mSampleRate) Hz, \(channels) ch, \(stream.mBitsPerChannel) bit, flags \(stream.mFormatFlags)")
        }
        self.deviceID = deviceID
        self.format = format
    }

    /// True once the device is seen to deliver something other than `format`:
    /// its rate or its channels changed under the IOProc. A device that
    /// cannot be read says nothing — one on its way out is for whoever
    /// watches the device list, not a format change.
    var formatChanged: Bool {
        let channels = deviceID.readInputChannelCount()
        guard channels > 0, let stream = deviceID.readInputStreamFormat() else { return false }
        return channels != format.channelCount || stream.mSampleRate != format.sampleRate
    }

    /// Frames the device skipped for us (an IO overload) that went to the
    /// handler as silence, and how many times. Read after `stop`.
    var skipped: (frames: Int, times: Int) {
        (relay.skippedFrames, relay.skips)
    }

    /// Starts IO; `onBuffer` gets every cycle's input with the host time of
    /// its first frame. Cycles the device skipped come as silence of the
    /// same length, so the stream stays on the clock; a break of `limit`
    /// seconds or more is left as it is — the capture sees those by the
    /// clock and fills them itself.
    /// shortcut: a device that also has output streams runs them for this
    /// IOProc too, playing the zeros the HAL hands us; switch them off with
    /// kAudioDevicePropertyIOProcStreamUsage if that ever shows.
    func start(fillingBreaksUnder limit: TimeInterval, onBuffer: @escaping AVAudioNodeTapBlock) throws {
        let format = self.format
        let relay = self.relay
        let queue = self.queue
        relay.handler = onBuffer
        var created: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&created, deviceID, nil) { _, input, inputTime, _, _ in
            // Both buffers below are handed to the queue and not touched here again.
            nonisolated(unsafe) let buffer: AVAudioPCMBuffer
            guard let copied = Self.deinterleaved(input, format: format) else { return }
            buffer = copied
            let stamp = inputTime.pointee
            let hostTime = stamp.mFlags.contains(.hostTimeValid) ? stamp.mHostTime : mach_absolute_time()
            var missed = 0
            if stamp.mFlags.contains(.sampleTimeValid) {
                missed = Self.missedFrames(
                    expected: relay.nextSampleTime, actual: stamp.mSampleTime,
                    cycle: Int(buffer.frameLength), limit: Int(limit * format.sampleRate)
                )
                relay.nextSampleTime = stamp.mSampleTime + Double(buffer.frameLength)
            }
            // A fresh buffer is zeroed: this is the silence.
            nonisolated(unsafe) let silence = missed > 0
                ? AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(missed)) : nil
            if let silence {
                silence.frameLength = AVAudioFrameCount(missed)
                relay.skippedFrames += missed
                relay.skips += 1
            }
            queue.async {
                if let silence {
                    let length = AVAudioTime.hostTime(forSeconds: Double(silence.frameLength) / format.sampleRate)
                    relay.handler?(silence, AVAudioTime(hostTime: hostTime - min(hostTime, length)))
                }
                relay.handler?(buffer, AVAudioTime(hostTime: hostTime))
            }
        }
        guard status == noErr, let created else { throw Failure.hal("AudioDeviceCreateIOProcID", status) }
        status = AudioDeviceStart(deviceID, created)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(deviceID, created)
            throw Failure.hal("AudioDeviceStart", status)
        }
        procID = created
    }

    /// Stops IO. Nothing of ours runs once this returns: the caller writes
    /// the file's tail next. Errors are not news — the device may be gone,
    /// and then the HAL may keep the IOProc's block: the handler is let go
    /// here, so the track's file it holds is not kept open with it.
    func stop() {
        guard let procID else { return }
        AudioDeviceStop(deviceID, procID)
        AudioDeviceDestroyIOProcID(deviceID, procID)
        self.procID = nil
        let relay = self.relay
        queue.sync { relay.handler = nil }
    }

    /// Frames the device skipped between two cycles, by its own sample
    /// counter. 0 when the cycles are contiguous or the counter is not known
    /// or went back; when the jump is under one cycle — whole cycles are
    /// what an overload drops; and when it is `limit` frames or more.
    static func missedFrames(expected: Double?, actual: Double, cycle: Int, limit: Int) -> Int {
        guard let expected else { return 0 }
        let missed = (actual - expected).rounded()
        return missed >= Double(max(cycle, 1)) && missed < Double(limit) ? Int(missed) : 0
    }

    /// Copies what an IOProc got into a buffer in `format`. The list holds
    /// one buffer per stream, each with its channels interleaved; in order
    /// they are the channels of `format`. nil when the list is not what
    /// `format` says (the device changed under the IOProc) or a stream is off.
    static func deinterleaved(_ list: UnsafePointer<AudioBufferList>, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        let sampleSize = MemoryLayout<Float32>.size
        guard let first = buffers.first, first.mNumberChannels > 0,
              buffers.reduce(0, { $0 + $1.mNumberChannels }) == format.channelCount
        else { return nil }
        let frames = Int(first.mDataByteSize) / (sampleSize * Int(first.mNumberChannels))
        guard frames > 0,
              let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = out.floatChannelData
        else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        var channel = 0
        for buffer in buffers {
            let width = Int(buffer.mNumberChannels)
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float32.self),
                  Int(buffer.mDataByteSize) >= frames * width * sampleSize
            else { return nil }
            for offset in 0 ..< width {
                let target = channels[channel + offset]
                for frame in 0 ..< frames { target[frame] = samples[frame * width + offset] }
            }
            channel += width
        }
        return out
    }
}
