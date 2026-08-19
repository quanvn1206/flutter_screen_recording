import Flutter
import UIKit
import ReplayKit
import AVFoundation

public class SwiftFlutterScreenRecordingPlugin: NSObject, FlutterPlugin {
    
    let recorder = RPScreenRecorder.shared()
    var videoWriter: AVAssetWriter?
    var videoWriterInput: AVAssetWriterInput?
    var audioWriterInput: AVAssetWriterInput?
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
                audioWriterInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                audioWriterInput?.expectsMediaDataInRealTime = true
                videoWriter?.add(audioWriterInput!)
            }
            
            // Iniciar la captura con ReplayKit
            recorder.isMicrophoneEnabled = recordAudio
            recorder.startCapture(handler: { [weak self] sampleBuffer, sampleBufferType, error in
                guard let self = self, self.isRecording, error == nil else { return }
                
                switch sampleBufferType {
                case .video:
                    self.handleVideoBuffer(sampleBuffer)
                case .audioMic:
                    if recordAudio {
                        self.handleAudioBuffer(sampleBuffer)
                    }
                default:
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

    func handleAudioBuffer(_ sampleBuffer: CMSampleBuffer) {
        writerQueue.sync {
            // Añadir el audio al video — solo despues de que la sesion de
            // video haya arrancado realmente (ver comentario en sessionStarted).
            guard let writer = videoWriter, let input = audioWriterInput, sessionStarted else { return }

            if writer.status == .writing && input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
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
        if #available(iOS 11.0, *) {
            recorder.stopCapture { [weak self] error in
                guard let self = self else { return }
                
                self.videoWriterInput?.markAsFinished()
                self.audioWriterInput?.markAsFinished()
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