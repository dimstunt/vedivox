import CoreAudio
import Foundation

/// The system's audio device list changed: a microphone was plugged in or
/// out. For views that show what is connected (Settings → Recording,
///); the recording itself listens on its own (`MicrophoneCapture`).
enum AudioDeviceChanges {
    private final class Box: Sendable {
        let continuation: AsyncStream<Void>.Continuation
        init(_ continuation: AsyncStream<Void>.Continuation) { self.continuation = continuation }
    }

    private static let address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
    )

    /// A C callback, not a block: a block listener cannot be removed from
    /// Swift (see `MicrophoneCapture.deviceEvent`). Runs on the HAL thread.
    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, clientData in
        guard let clientData else { return noErr }
        Unmanaged<Box>.fromOpaque(clientData).takeUnretainedValue().continuation.yield()
        return noErr
    }

    /// One element per change, a burst per plug; ends when the consumer stops.
    static func stream() -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = Unmanaged.passRetained(Box(continuation))
            var address = address
            let system = AudioObjectID(kAudioObjectSystemObject)
            let err = AudioObjectAddPropertyListener(system, &address, listener, box.toOpaque())
            guard err == noErr else {
                Log.error("Device list listener install failed: \(err)")
                box.release()
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                var address = Self.address
                AudioObjectRemovePropertyListener(system, &address, listener, box.toOpaque())
                // A callback already on the HAL thread may still read the box: free it a moment later.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { box.release() }
            }
        }
    }
}
