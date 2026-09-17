import Flutter
import UIKit
import ReplayKit
import AVFoundation

public class SwiftFlutterScreenRecordingPlugin: NSObject, FlutterPlugin {

    let recorder = RPScreenRecorder.shared()
    var videoWriter: AVAssetWriter?
    var videoWriterInput: AVAssetWriterInput?
    var micAudioWriterInput: AVAssetWriterInput?
    var videoOutputURL: URL?
    var isRecording = false
    var firstTimestamp: CMTime?
    let screenSize = UIScreen.main.bounds

    // ReplayKit invokes the `startCapture` handler for video and audio
    // sample buffers concurrently, on two separate internal queues. All
    // reads/writes of the writer/session state below must go through this
    // queue, or the audio queue can observe `videoWriter.status == .writing`
    // (set synchronously inside `startWriting()`) in the brief window before
    // `startSession(atSourceTime:)` has actually run on the video queue —
    // and then crash appending a sample buffer with "Must start a session
    // ... first". `sessionStarted` (not `writer.status`) is the gate because
    // it is only ever flipped true after `startSession` has actually returned.
    private let writerQueue = DispatchQueue(label: "com.flutter_screen_recording.writer")
    private var sessionStarted = false

    // Diagnostics kept from the mic-audio investigation: cheap, read-only,
    // and useful for confirming mic capture is healthy on any future report.
    private var micAudioBufferCount = 0
    private var micAudioByteTotal = 0
    private var micAudioAppendFailureCount = 0
    private var loggedMicAudioFormat = false
    // Peak absolute sample value seen on the mic track this recording.
    // Buffer/byte counts alone can't tell real audio apart from well-formed
    // silence (silence still produces identically-sized buffers) — this is
    // the read-only check for that. 0 means the hardware delivered silence;
    // a normal talking voice should peak well into the thousands (Int16
    // range is ±32767).
    private var micPeakAmplitude: Int16 = 0

    private func sampleByteLength(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        return CMBlockBufferGetDataLength(blockBuffer)
    }

    // Read-only — never mutates the buffer, so this cannot introduce the
    // kind of corruption an earlier gain-scaling attempt did (see git
    // history: raw PCM buffer mutation caused audible static and was
    // reverted). Assumes native-endian, packed Int16 mono, matching the
    // confirmed audioMic format (formatFlags=12 → signedInteger+packed, no
    // float, no big-endian bit). Silently no-ops for any other format.
    private func updateMicPeakAmplitude(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat == 0,
              asbd.mBitsPerChannel == 16,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0)
        else { return }

        var lengthAtOffset = 0
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let dataPointer else { return }

        let sampleCount = totalLength / MemoryLayout<Int16>.size
        dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
            for i in 0..<sampleCount {
                let magnitude = samples[i] == Int16.min ? Int16.max : abs(samples[i])
                if magnitude > micPeakAmplitude {
                    micPeakAmplitude = magnitude
                }
            }
        }
    }

    private func permissionDescription(_ permission: AVAudioSession.RecordPermission) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown(\(permission.rawValue))"
        }
    }

    /// ReplayKit's `.audioMic` stream depends on the process-wide audio
    /// session at the instant capture starts. Own that setup in the plugin so
    /// host apps cannot accidentally leave the recorder on an output-only
    /// route. In particular, do not request Bluetooth A2DP here: it has no
    /// microphone input; `.allowBluetooth` chooses two-way HFP instead.
    private func prepareMicrophoneAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        guard session.recordPermission == .granted else {
            throw NSError(
                domain: "flutter_screen_recording",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Microphone permission is not granted"]
            )
        }
        try session.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: [.allowBluetooth]
        )
        try session.setActive(true, options: [])
    }

    private func logAudioFormatOnce(_ sampleBuffer: CMSampleBuffer, label: String, logged: inout Bool) {
        guard !logged,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee
        else { return }
        logged = true
        print("[flutter_screen_recording][diag] \(label) format: sampleRate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) bitsPerChannel=\(asbd.mBitsPerChannel) formatFlags=\(asbd.mFormatFlags)")
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "flutter_screen_recording", binaryMessenger: registrar.messenger())
        let instance = SwiftFlutterScreenRecordingPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "startRecordScreen":
            guard let args = call.arguments as? [String: Any],
                  let name = args["name"] as? String,
                  let includeAudio = args["audio"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGUMENTS", message: "Missing arguments", details: nil))
                return
            }
            startRecording(videoName: name, recordAudio: includeAudio, result: result)
        case "stopRecordScreen":
            stopRecording(result: result)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    func startRecording(videoName: String, recordAudio: Bool, result: @escaping FlutterResult) {
        guard !isRecording else {
            result(FlutterError(code: "ALREADY_RECORDING", message: "Recording is already in progress", details: nil))
            return
        }

        isRecording = true
        writerQueue.sync { sessionStarted = false }

        if recordAudio {
            do {
                try prepareMicrophoneAudioSession()
            } catch {
                isRecording = false
                result(FlutterError(code: "MICROPHONE_UNAVAILABLE", message: "Unable to prepare the microphone for screen recording", details: error.localizedDescription))
                return
            }
        }

        // Configurar la ruta del archivo de video
        let documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        videoOutputURL = URL(fileURLWithPath: documentsPath).appendingPathComponent("\(videoName).mp4")

        // Eliminar el archivo si ya existe
        if FileManager.default.fileExists(atPath: videoOutputURL!.path) {
            try? FileManager.default.removeItem(at: videoOutputURL!)
        }

        if #available(iOS 11.0, *) {
            // Crear el AVAssetWriter
            do {
                videoWriter = try AVAssetWriter(outputURL: videoOutputURL!, fileType: .mp4)
            } catch {
                isRecording = false
                result(FlutterError(code: "FILE_ERROR", message: "Unable to create video file", details: error.localizedDescription))
                return
            }

            // Configurar la entrada de video
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: screenSize.width,
                AVVideoHeightKey: screenSize.height
            ]
            videoWriterInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoWriterInput?.expectsMediaDataInRealTime = true
            videoWriter?.add(videoWriterInput!)

            // Configurar la entrada de audio si es necesario. Mic-only: an
            // earlier version also captured ReplayKit's `.audioApp` stream as
            // a second track (to include narration/SFX in the recording),
            // but no combination of two-track playback, raw PCM gain
            // scaling, or an AVFoundation-driven single-track mixdown made
            // the mic audible in the resulting file — despite on-device
            // diagnostics proving ReplayKit captured real, loud mic audio
            // (peak amplitude ~30000/32767) at every step. Back to the
            // simple, previously-working shape: one writer input, fed only
            // by `.audioMic`.
            if recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2
                ]
                micAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                micAudioWriterInput?.expectsMediaDataInRealTime = true
                videoWriter?.add(micAudioWriterInput!)
            }

            // Iniciar la captura con ReplayKit
            recorder.isMicrophoneEnabled = recordAudio
            micAudioBufferCount = 0
            micAudioByteTotal = 0
            micAudioAppendFailureCount = 0
            loggedMicAudioFormat = false
            micPeakAmplitude = 0
            if recordAudio {
                let session = AVAudioSession.sharedInstance()
                print("[flutter_screen_recording][diag] starting capture: recordPermission=\(permissionDescription(session.recordPermission)) category=\(session.category.rawValue) isInputAvailable=\(session.isInputAvailable) isMicrophoneEnabled=\(recorder.isMicrophoneEnabled)")
            }
            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
                guard let self = self, self.isRecording, error == nil else { return }

                switch sampleBufferType {
                case .video:
                    self.handleVideoBuffer(sampleBuffer)
                case .audioApp:
                    // Not recorded — see the comment above `micAudioWriterInput`.
                    break
                case .audioMic:
                    if recordAudio {
                        self.logAudioFormatOnce(sampleBuffer, label: "audioMic", logged: &self.loggedMicAudioFormat)
                        self.micAudioBufferCount += 1
                        self.micAudioByteTotal += self.sampleByteLength(sampleBuffer)
                        self.updateMicPeakAmplitude(sampleBuffer)
                        if self.micAudioBufferCount % 50 == 0 {
                            print("[flutter_screen_recording][diag] mic buffers so far=\(self.micAudioBufferCount) bytes=\(self.micAudioByteTotal) appendFailures=\(self.micAudioAppendFailureCount)")
                        }
                        self.handleAudioBuffer(sampleBuffer, input: self.micAudioWriterInput)
                    }
                @unknown default:
                    break
                }
            }) { error in
                if let error = error {
                    self.isRecording = false
                    result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to start screen recording", details: error.localizedDescription))
                } else {
                    result(true)
                }
            }
        }
        else {
            result(FlutterError(code: "IOS_VERSION_ERROR", message: "This feature is only available on iOS 11 or later", details: nil))
        }
    }

    func handleVideoBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.sync {
            // Añadir el video al archivo
            guard let writer = videoWriter, let input = videoWriterInput else { return }

            if !sessionStarted {
                firstTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                writer.startWriting()
                writer.startSession(atSourceTime: firstTimestamp!)
                sessionStarted = true
            }

            if writer.status == .writing && input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }
    }

    func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?) {
        writerQueue.sync {
            guard let writer = videoWriter, let input, sessionStarted else {
                micAudioAppendFailureCount += 1
                return
            }

            if writer.status == .writing && input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            } else {
                micAudioAppendFailureCount += 1
            }
        }
    }

    func stopRecording(result: @escaping FlutterResult) {
        // Detener la captura con ReplayKit
        guard isRecording else {
            result(FlutterError(code: "NOT_RECORDING", message: "No recording in progress", details: nil))
            return
        }
        isRecording = false
        print("[flutter_screen_recording][diag] stopping capture: micAudioBuffers=\(micAudioBufferCount) bytes=\(micAudioByteTotal) micAppendFailures=\(micAudioAppendFailureCount) micPeakAmplitude=\(micPeakAmplitude) (0=silence, ~1000s+=real speech)")
        if #available(iOS 11.0, *) {
            recorder.stopCapture { [weak self] error in
                guard let self = self else { return }

                self.videoWriterInput?.markAsFinished()
                self.micAudioWriterInput?.markAsFinished()
                self.videoWriter?.finishWriting {
                    if let error = error {
                        result(FlutterError(code: "STOP_ERROR", message: "Failed to stop recording", details: error.localizedDescription))
                    } else {
                        // `AVAssetWriter.finishWriting`'s completion runs on an internal
                        // background queue, not the main thread. This used to construct
                        // (never present — dead code) a UIAlertController here, which
                        // touches UIKit off the main thread and trips the Main Thread
                        // Checker: "Modifying properties of a view's layer off the main
                        // thread is not allowed." Just removed — nothing used the alert.
                        result(self.videoOutputURL?.path)
                    }
                }
            }
        }
        else {
            result(FlutterError(code: "IOS_VERSION_ERROR", message: "This feature is only available on iOS 11 or later", details: nil))
        }
    }
}
