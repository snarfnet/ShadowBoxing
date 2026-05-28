import AVFoundation
import UIKit
import Photos
import Vision

@Observable
final class VideoComposer {
    var isRecording = false
    var recordingDuration: TimeInterval = 0
    var savedMessage: String?

    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var startTime: CMTime?
    private var frameCount: Int = 0
    private var timer: Timer?
    private var recordStart: Date?

    private var lastScoreUpdate: CFTimeInterval = 0
    private var stableStats = SessionStats()
    private let scoreUpdateInterval: CFTimeInterval = 1.0

    private let outputWidth = 1920
    private let outputHeight = 1080
    private let isEnglish = Locale.preferredLanguages.first?.hasPrefix("en") == true

    func startRecording() {
        guard !isRecording else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("boxing_\(Int(Date().timeIntervalSince1970)).mp4")
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return }

        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: outputWidth,
            AVVideoHeightKey: outputHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 5_000_000,
                AVVideoMaxKeyFrameIntervalKey: 30,
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true

        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth,
            kCVPixelBufferHeightKey as String: outputHeight,
        ]
        let adapt = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attrs)

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        assetWriter = writer
        videoInput = input
        adaptor = adapt
        startTime = nil
        frameCount = 0
        isRecording = true
        recordStart = Date()

        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            if let start = self?.recordStart {
                self?.recordingDuration = Date().timeIntervalSince(start)
            }
        }
    }

    func appendFrame(cameraImage: UIImage, pose: BodyPose?, stats: SessionStats, lastPunch: PunchType?, lastPower: Double, timestamp: CMTime) {
        guard isRecording, let input = videoInput, let adapt = adaptor, input.isReadyForMoreMediaData else { return }

        if startTime == nil { startTime = timestamp }
        let pt = CMTimeSubtract(timestamp, startTime!)
        guard pt.seconds >= 0 else { return }

        let now = CACurrentMediaTime()
        if now - lastScoreUpdate >= scoreUpdateInterval {
            stableStats = stats
            lastScoreUpdate = now
        }
        stableStats.totalPunches = stats.totalPunches
        stableStats.duration = stats.duration
        stableStats.punchesPerMinute = stats.punchesPerMinute

        let composed = composeFrame(camera: cameraImage, pose: pose, stats: stableStats, lastPunch: lastPunch, lastPower: lastPower)

        var pixelBuffer: CVPixelBuffer?
        if let pool = adapt.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        }
        guard let pb = pixelBuffer ?? createPixelBuffer() else { return }
        renderImage(composed, into: pb)
        adapt.append(pb, withPresentationTime: pt)
        frameCount += 1
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        timer?.invalidate()
        timer = nil

        guard let writer = assetWriter else { return }
        videoInput?.markAsFinished()

        let url = writer.outputURL
        writer.finishWriting { [weak self] in
            guard writer.status == .completed else {
                DispatchQueue.main.async { self?.savedMessage = "Recording failed" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self?.savedMessage = success
                        ? (self?.isEnglish == true ? "Saved to Photos" : "写真に保存しました")
                        : "Save failed"
                }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Compose

    private func composeFrame(camera: UIImage, pose: BodyPose?, stats: SessionStats, lastPunch: PunchType?, lastPower: Double) -> UIImage {
        let size = CGSize(width: outputWidth, height: outputHeight)
        let reportW = CGFloat(outputWidth) * 0.50
        let cameraW = CGFloat(outputWidth) - reportW
        let h = CGFloat(outputHeight)

        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let gc = ctx.cgContext

            // Left: Report
            gc.setFillColor(UIColor(red: 0.05, green: 0.02, blue: 0.08, alpha: 1).cgColor)
            gc.fill(CGRect(x: 0, y: 0, width: reportW, height: h))
            drawReport(gc: gc, stats: stats, lastPunch: lastPunch, lastPower: lastPower, width: reportW, height: h)

            // Right: Camera
            let cameraRect = CGRect(x: reportW, y: 0, width: cameraW, height: h)
            let imgRatio = camera.size.width / camera.size.height
            let rectRatio = cameraW / h
            var drawRect: CGRect
            if imgRatio > rectRatio {
                let dH = h; let dW = dH * imgRatio
                drawRect = CGRect(x: reportW + (cameraW - dW) / 2, y: 0, width: dW, height: dH)
            } else {
                let dW = cameraW; let dH = dW / imgRatio
                drawRect = CGRect(x: reportW, y: (h - dH) / 2, width: dW, height: dH)
            }
            gc.saveGState()
            gc.clip(to: cameraRect)
            camera.draw(in: drawRect)
            gc.restoreGState()

            if let pose = pose {
                drawSkeleton(gc: gc, pose: pose, rect: cameraRect)
            }

            // Divider
            gc.setStrokeColor(UIColor.red.withAlphaComponent(0.6).cgColor)
            gc.setLineWidth(2)
            gc.move(to: CGPoint(x: reportW, y: 0))
            gc.addLine(to: CGPoint(x: reportW, y: h))
            gc.strokePath()
        }
    }

    private func drawReport(gc: CGContext, stats: SessionStats, lastPunch: PunchType?, lastPower: Double, width: CGFloat, height: CGFloat) {
        let pad: CGFloat = 36
        var y: CGFloat = 30

        let titleFont = UIFont.monospacedSystemFont(ofSize: 38, weight: .bold)
        let subFont = UIFont.monospacedSystemFont(ofSize: 24, weight: .medium)
        let bigFont = UIFont.monospacedSystemFont(ofSize: 72, weight: .black)
        let gradeFont = UIFont.monospacedSystemFont(ofSize: 90, weight: .black)
        let labelFont = UIFont.monospacedSystemFont(ofSize: 30, weight: .bold)
        let valueFont = UIFont.monospacedSystemFont(ofSize: 34, weight: .black)
        let smallFont = UIFont.monospacedSystemFont(ofSize: 22, weight: .medium)

        // Title
        draw("SHADOW BOXING", at: CGPoint(x: pad, y: y), font: titleFont, color: .red, gc: gc)
        y += 48
        draw(isEnglish ? "AI Punch Tracker" : "AIパンチトラッカー", at: CGPoint(x: pad, y: y), font: subFont, color: UIColor.red.withAlphaComponent(0.5), gc: gc)
        y += 36

        drawDivider(gc: gc, y: y, x1: pad, x2: width - pad, color: .red)
        y += 16

        // Punch count
        draw("\(stats.totalPunches)", at: CGPoint(x: pad, y: y), font: bigFont, color: .red, gc: gc)
        let punchLabel = isEnglish ? "PUNCHES" : "パンチ"
        draw(punchLabel, at: CGPoint(x: pad + 180, y: y + 30), font: subFont, color: UIColor.red.withAlphaComponent(0.6), gc: gc)
        y += 90

        // Last punch
        if let punch = lastPunch {
            let pName = isEnglish ? punch.rawValue : punch.jaName
            draw(pName.uppercased(), at: CGPoint(x: pad, y: y), font: labelFont, color: .white, gc: gc)

            // Power bar
            y += 38
            let barW = width - pad * 2
            let barH: CGFloat = 14
            gc.setFillColor(UIColor.white.withAlphaComponent(0.1).cgColor)
            gc.fill(CGRect(x: pad, y: y, width: barW, height: barH))
            let pColor = colorForPower(lastPower)
            gc.setFillColor(pColor.cgColor)
            gc.fill(CGRect(x: pad, y: y, width: barW * min(CGFloat(lastPower) / 100, 1), height: barH))

            let pwrText = String(format: "PWR %.0f%%", lastPower)
            draw(pwrText, at: CGPoint(x: pad, y: y + barH + 4), font: smallFont, color: pColor, gc: gc)
            y += 52
        } else {
            y += 90
        }

        // PPM
        draw(String(format: "%.0f", stats.punchesPerMinute), at: CGPoint(x: pad, y: y), font: valueFont, color: .orange, gc: gc)
        draw("PPM", at: CGPoint(x: pad + 100, y: y + 4), font: smallFont, color: UIColor.orange.withAlphaComponent(0.6), gc: gc)
        y += 46

        drawDivider(gc: gc, y: y, x1: pad, x2: width - pad, color: .red)
        y += 16

        // Form scores
        let formItems: [(String, Double)] = [
            (isEnglish ? "Guard" : "ガード", stats.formScore.guardScore),
            (isEnglish ? "Stance" : "スタンス", stats.formScore.stanceScore),
            (isEnglish ? "Rotation" : "回転", stats.formScore.rotationScore),
            (isEnglish ? "Chin" : "顎の引き", stats.formScore.chinScore),
        ]
        for (label, score) in formItems {
            let c = colorForScore(score)
            draw(label, at: CGPoint(x: pad, y: y), font: smallFont, color: c.withAlphaComponent(0.9), gc: gc)
            let valText = String(format: "%.0f%%", score)
            let valSize = (valText as NSString).size(withAttributes: [.font: valueFont])
            draw(valText, at: CGPoint(x: width - pad - valSize.width, y: y - 4), font: valueFont, color: c, gc: gc)
            y += 40
        }

        y += 10
        drawDivider(gc: gc, y: y, x1: pad, x2: width - pad, color: .red)
        y += 16

        // Boxer grade
        let grade = stats.rating.grade
        let gColor = colorForScore(stats.rating.overall)
        draw(grade, at: CGPoint(x: pad, y: y), font: gradeFont, color: gColor, gc: gc)
        let gSize = (grade as NSString).size(withAttributes: [.font: gradeFont])
        draw(stats.rating.title, at: CGPoint(x: pad + gSize.width + 14, y: y + 30), font: labelFont, color: gColor, gc: gc)

        // Duration bottom right
        let mins = Int(stats.duration) / 60
        let secs = Int(stats.duration) % 60
        let durText = String(format: "%d:%02d", mins, secs)
        let durSize = (durText as NSString).size(withAttributes: [.font: subFont])
        draw(durText, at: CGPoint(x: width - pad - durSize.width, y: height - 40), font: subFont, color: UIColor.red.withAlphaComponent(0.4), gc: gc)
    }

    private func drawSkeleton(gc: CGContext, pose: BodyPose, rect: CGRect) {
        let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftShoulder, .rightShoulder), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
            (.leftHip, .rightHip), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
            (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
            (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
            (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
            (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
        ]
        gc.setStrokeColor(UIColor.red.withAlphaComponent(0.8).cgColor)
        gc.setLineWidth(4)
        for (from, to) in connections {
            guard let p1 = pose.point(from), let p2 = pose.point(to) else { continue }
            let sp1 = CGPoint(x: rect.minX + p1.x * rect.width, y: rect.minY + p1.y * rect.height)
            let sp2 = CGPoint(x: rect.minX + p2.x * rect.width, y: rect.minY + p2.y * rect.height)
            gc.move(to: sp1)
            gc.addLine(to: sp2)
        }
        gc.strokePath()

        for (_, point) in pose.joints {
            let sp = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            gc.setFillColor(UIColor.red.cgColor)
            gc.fillEllipse(in: CGRect(x: sp.x - 6, y: sp.y - 6, width: 12, height: 12))
            gc.setStrokeColor(UIColor.white.cgColor)
            gc.setLineWidth(2)
            gc.strokeEllipse(in: CGRect(x: sp.x - 6, y: sp.y - 6, width: 12, height: 12))
        }
    }

    // MARK: - Helpers

    private func createPixelBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: outputWidth, kCVPixelBufferHeightKey as String: outputHeight,
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        return CVPixelBufferCreate(kCFAllocatorDefault, outputWidth, outputHeight, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer) == kCVReturnSuccess ? buffer : nil
    }

    private func renderImage(_ image: UIImage, into pb: CVPixelBuffer) {
        guard let cgImage = image.cgImage else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: outputWidth, height: outputHeight, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cgImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        CVPixelBufferUnlockBaseAddress(pb, [])
    }

    private func draw(_ text: String, at point: CGPoint, font: UIFont, color: UIColor, gc: CGContext) {
        (text as NSString).draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private func drawDivider(gc: CGContext, y: CGFloat, x1: CGFloat, x2: CGFloat, color: UIColor) {
        gc.setStrokeColor(color.withAlphaComponent(0.3).cgColor)
        gc.setLineWidth(1)
        gc.move(to: CGPoint(x: x1, y: y))
        gc.addLine(to: CGPoint(x: x2, y: y))
        gc.strokePath()
    }

    private func colorForScore(_ score: Double) -> UIColor {
        switch score {
        case 90...: return UIColor(red: 0.3, green: 1, blue: 0.5, alpha: 1)
        case 80..<90: return UIColor(red: 0.5, green: 1, blue: 0.8, alpha: 1)
        case 70..<80: return .yellow
        case 60..<70: return .orange
        default: return UIColor(red: 1, green: 0.4, blue: 0.4, alpha: 1)
        }
    }

    private func colorForPower(_ power: Double) -> UIColor {
        switch power {
        case 80...: return UIColor(red: 1, green: 0.2, blue: 0.2, alpha: 1)
        case 60..<80: return .orange
        case 40..<60: return .yellow
        default: return UIColor(red: 0.5, green: 1, blue: 0.8, alpha: 1)
        }
    }
}
