import AVFoundation
import Vision
import UIKit

@Observable
final class CameraManager: NSObject {
    let session = AVCaptureSession()
    var currentPose: BodyPose?
    var isBackCamera = false  // front camera default for boxing

    var onFrame: ((UIImage, CMTime, BodyPose?) -> Void)?

    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.pose.queue")
    private let confidenceThreshold: Float = 0.1
    private let ciContext = CIContext()
    private var lastFrameForward: CFTimeInterval = 0
    private let frameInterval: CFTimeInterval = 1.0 / 10.0

    func start() {
        guard !session.isRunning else { return }
        queue.async { [weak self] in
            self?.configureSession()
            self?.session.startRunning()
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.session.stopRunning()
        }
    }

    func flipCamera() {
        isBackCamera.toggle()
        queue.async { [weak self] in
            self?.configureSession()
        }
    }

    private func configureSession() {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.sessionPreset = .high

        let position: AVCaptureDevice.Position = isBackCamera ? .back : .front
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) { session.addInput(input) }

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            if !isBackCamera { connection.isVideoMirrored = true }
        }

        session.commitConfiguration()
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        var detectedPose: BodyPose?

        let request = VNDetectHumanBodyPoseRequest { [weak self] request, _ in
            guard let self = self,
                  let results = request.results as? [VNHumanBodyPoseObservation],
                  let observation = results.first else { return }

            var pose = BodyPose()
            let jointNames: [VNHumanBodyPoseObservation.JointName] = [
                .nose, .leftEye, .rightEye, .leftEar, .rightEar,
                .leftShoulder, .rightShoulder,
                .leftElbow, .rightElbow,
                .leftWrist, .rightWrist,
                .leftHip, .rightHip,
                .leftKnee, .rightKnee,
                .leftAnkle, .rightAnkle,
                .neck, .root
            ]

            for name in jointNames {
                guard let point = try? observation.recognizedPoint(name),
                      point.confidence > self.confidenceThreshold else { continue }
                pose.joints[name] = CGPoint(x: point.location.x, y: 1 - point.location.y)
            }

            detectedPose = pose
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])

        let poseForUI = detectedPose
        DispatchQueue.main.async { [weak self] in
            self?.currentPose = poseForUI
        }

        if let onFrame = onFrame {
            let now = CACurrentMediaTime()
            guard now - lastFrameForward >= frameInterval else { return }
            lastFrameForward = now

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            if let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) {
                let uiImage = UIImage(cgImage: cgImage)
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                onFrame(uiImage, timestamp, detectedPose)
            }
        }
    }
}
