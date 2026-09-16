import Flutter
import UIKit
import ReplayKit
import AVFoundation
import AudioToolbox

public class SwiftFlutterScreenRecordingPlugin: NSObject, FlutterPlugin {

    // `RPScreenRecorder`'s `.audioMic` samples arrive far quieter than the
    // `.audioApp` samples for the same recording — a well-documented
    // ReplayKit behavior (no app-side input gain control is exposed), not a
    // bug specific to this fork. Since both tracks get mixed together at
    // playback, an un-boosted mic track reads as "almost inaudible" next to
    // narration/SFX. These factors are empirical starting points — tune by
    // ear on a real device (the simulator's mic capture isn't
    // representative) if voice still needs adjusting.
    private let micGainFactor: Float = 3.0
    private let appAudioGainFactor: Float = 0.7

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
            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
                guard let self = self, self.isRecording, error == nil else { return }
                
                switch sampleBufferType {
                case .video:
                    self.handleVideoBuffer(sampleBuffer)
                case .audioApp:
                    if recordAudio {
                        self.handleAudioBuffer(sampleBuffer, input: self.appAudioWriterInput, gain: self.appAudioGainFactor)
                    }
                case .audioMic:
                    if recordAudio {
                        self.handleAudioBuffer(sampleBuffer, input: self.micAudioWriterInput, gain: self.micGainFactor)
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

    func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer, input: AVAssetWriterInput?, gain: Float) {
        writerQueue.sync {
            // Each ReplayKit audio source has its own AVAssetWriter track. The
            // streams arrive independently and must not be appended to one
            // shared input as if they were a single chronological stream.
            guard let writer = videoWriter, let input, sessionStarted else { return }

            if writer.status == .writing && input.isReadyForMoreMediaData {
                input.append(adjustGain(of: sampleBuffer, factor: gain))
            }
        }
    }

    // Scales the PCM samples backing `sampleBuffer` in place by `factor`,
    // clamped to the format's representable range to avoid clipping
    // artifacts. ReplayKit hands each capture handler invocation a buffer
    // that isn't referenced anywhere else afterward, so in-place mutation is
    // safe. Falls back to returning the buffer untouched (rather than
    // crashing) for any format/layout this doesn't recognize — losing the
    // gain adjustment is far preferable to losing the recording.
    private func adjustGain(of sampleBuffer: CMSampleBuffer, factor: Float) -> CMSampleBuffer {
        guard factor != 1.0,
              let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              asbdPointer.pointee.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer),
              CMBlockBufferIsRangeContiguous(blockBuffer, atOffset: 0, length: 0)
        else {
            return sampleBuffer
        }

        let asbd = asbdPointer.pointee
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
        guard status == kCMBlockBufferNoErr, let dataPointer else { return sampleBuffer }

        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        switch (isFloat, asbd.mBitsPerChannel) {
        case (true, 32):
            let sampleCount = totalLength / MemoryLayout<Float32>.size
            dataPointer.withMemoryRebound(to: Float32.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    samples[i] = max(-1.0, min(1.0, samples[i] * factor))
                }
            }
        case (false, 16):
            let sampleCount = totalLength / MemoryLayout<Int16>.size
            dataPointer.withMemoryRebound(to: Int16.self, capacity: sampleCount) { samples in
                for i in 0..<sampleCount {
                    let scaled = Float(samples[i]) * factor
                    samples[i] = Int16(max(Float(Int16.min), min(Float(Int16.max), scaled)))
                }
            }
        default:
            break
        }

        return sampleBuffer
    }
    
    func stopRecording(result: @escaping FlutterResult) {
        // Detener la captura con ReplayKit
        guard isRecording else {
            result(FlutterError(code: "NOT_RECORDING", message: "No recording in progress", details: nil))
            return
        }
        isRecording = false
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
                        let alertController = UIAlertController(title: "Your video was successfully saved", message: nil, preferredStyle: .alert)
                        let defaultAction = UIAlertAction(title: "OK", style: .default, handler: nil)
                        alertController.addAction(defaultAction)
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