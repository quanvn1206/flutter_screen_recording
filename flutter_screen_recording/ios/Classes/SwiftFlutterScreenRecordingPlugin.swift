import Flutter
import UIKit
import ReplayKit
import AVFoundation

public class SwiftFlutterScreenRecordingPlugin: NSObject, FlutterPlugin {
    
    let recorder = RPScreenRecorder.shared()
    var videoWriter: AVAssetWriter?
    var videoWriterInput: AVAssetWriterInput?
    var appAudioWriterInput: AVAssetWriterInput?
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

    // TEMPORARY diagnostics for the "no mic audio" investigation. Printed
    // via `print()` so it shows up directly in `flutter run`'s console — no
    // Xcode attach needed. Safe to leave in (cheap counters, no behavior
    // change); remove once the mic issue is root-caused.
    private var appAudioBufferCount = 0
    private var micAudioBufferCount = 0
    private var appAudioByteTotal = 0
    private var micAudioByteTotal = 0
    private var micAudioAppendFailureCount = 0
    private var loggedAppAudioFormat = false
    private var loggedMicAudioFormat = false

    private func sampleByteLength(_ sampleBuffer: CMSampleBuffer) -> Int {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        return CMBlockBufferGetDataLength(blockBuffer)
    }

    private func permissionDescription(_ permission: AVAudioSession.RecordPermission) -> String {
        switch permission {
        case .granted: return "granted"
        case .denied: return "denied"
        case .undetermined: return "undetermined"
        @unknown default: return "unknown(\(permission.rawValue))"
        }
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
            
            // Configurar la entrada de audio si es necesario
            if recordAudio {
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 44100,
                    AVNumberOfChannelsKey: 2
                ]
                appAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                appAudioWriterInput?.expectsMediaDataInRealTime = true
                videoWriter?.add(appAudioWriterInput!)

                micAudioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                micAudioWriterInput?.expectsMediaDataInRealTime = true
                videoWriter?.add(micAudioWriterInput!)
            }
            
            // Iniciar la captura con ReplayKit
            recorder.isMicrophoneEnabled = recordAudio
            appAudioBufferCount = 0
            micAudioBufferCount = 0
            appAudioByteTotal = 0
            micAudioByteTotal = 0
            micAudioAppendFailureCount = 0
            loggedAppAudioFormat = false
            loggedMicAudioFormat = false
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
                    if recordAudio {
                        self.logAudioFormatOnce(sampleBuffer, label: "audioApp", logged: &self.loggedAppAudioFormat)
                        self.appAudioBufferCount += 1
                        self.appAudioByteTotal += self.sampleByteLength(sampleBuffer)
                        self.handleAudioBuffer(sampleBuffer, input: self.appAudioWriterInput)
                    }
                case .audioMic:
                    if recordAudio {
                        self.logAudioFormatOnce(sampleBuffer, label: "audioMic", logged: &self.loggedMicAudioFormat)
                        self.micAudioBufferCount += 1
                        self.micAudioByteTotal += self.sampleByteLength(sampleBuffer)
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
            // Each ReplayKit audio source has its own AVAssetWriter track. The
            // streams arrive independently and must not be appended to one
            // shared input as if they were a single chronological stream.
            let isMicInput = input === micAudioWriterInput
            guard let writer = videoWriter, let input, sessionStarted else {
                if isMicInput { micAudioAppendFailureCount += 1 }
                return
            }

            if writer.status == .writing && input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            } else if isMicInput {
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
        print("[flutter_screen_recording][diag] stopping capture: appAudioBuffers=\(appAudioBufferCount) bytes=\(appAudioByteTotal) | micAudioBuffers=\(micAudioBufferCount) bytes=\(micAudioByteTotal) micAppendFailures=\(micAudioAppendFailureCount)")
        if #available(iOS 11.0, *) {
            recorder.stopCapture { [weak self] error in
                guard let self = self else { return }

                self.videoWriterInput?.markAsFinished()
                self.appAudioWriterInput?.markAsFinished()
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