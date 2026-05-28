import SwiftUI
import AVFoundation
import Vision

struct ContentView: View {
    @State private var camera = CameraManager()
    @State private var detector = PunchDetector()
    @State private var composer = VideoComposer()
    @State private var showResults = false

    private let isEnglish = Locale.preferredLanguages.first?.hasPrefix("en") == true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if detector.isSessionActive {
                sessionView
            } else if showResults {
                resultsView
            } else {
                startView
            }
        }
        .statusBarHidden(detector.isSessionActive)
        .onAppear {
            camera.onFrame = { [detector, composer] image, time, pose in
                DispatchQueue.main.async {
                    if let pose = pose { detector.analyze(pose) }
                    if composer.isRecording {
                        composer.appendFrame(
                            cameraImage: image, pose: pose, stats: detector.stats,
                            lastPunch: detector.lastPunchType, lastPower: detector.lastPunchPower, timestamp: time
                        )
                    }
                }
            }
            camera.start()
        }
    }

    // MARK: - Start

    private var startView: some View {
        VStack(spacing: 30) {
            Spacer()
            Text("SHADOW\nBOXING")
                .font(.system(size: 56, weight: .black, design: .monospaced))
                .foregroundColor(.red)
                .multilineTextAlignment(.center)

            Text(isEnglish ? "AI Punch Tracker" : "AIパンチトラッカー")
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .foregroundColor(.red.opacity(0.6))

            Spacer()

            Button {
                detector.startSession()
            } label: {
                Text(isEnglish ? "START" : "スタート")
                    .font(.system(size: 24, weight: .black, design: .monospaced))
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18)
                    .background(.red)
                    .cornerRadius(16)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 60)
        }
    }

    // MARK: - Session

    private var sessionView: some View {
        ZStack {
            CameraPreview(session: camera.session)
                .ignoresSafeArea()

            // Skeleton overlay
            if let pose = camera.currentPose {
                SkeletonOverlay(pose: pose)
                    .ignoresSafeArea()
            }

            // HUD
            VStack {
                // Top bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(detector.stats.totalPunches)")
                            .font(.system(size: 56, weight: .black, design: .monospaced))
                            .foregroundColor(.red)
                        Text(isEnglish ? "PUNCHES" : "パンチ")
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundColor(.red.opacity(0.7))
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text(durationText)
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.6))

                        Text(String(format: "%.0f PPM", detector.stats.punchesPerMinute))
                            .font(.system(size: 16, weight: .medium, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)

                Spacer()

                // Last punch indicator
                if let punch = detector.lastPunchType {
                    lastPunchView(punch: punch)
                        .transition(.scale.combined(with: .opacity))
                        .id(detector.stats.totalPunches)
                }

                Spacer()

                // Bottom controls
                HStack(spacing: 30) {
                    // Record button
                    Button {
                        if composer.isRecording {
                            composer.stopRecording()
                        } else {
                            composer.startRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.6), lineWidth: 3)
                                .frame(width: 70, height: 70)
                            if composer.isRecording {
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(.red)
                                    .frame(width: 26, height: 26)
                            } else {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 56, height: 56)
                            }
                        }
                    }

                    // Stop session
                    Button {
                        if composer.isRecording { composer.stopRecording() }
                        detector.stopSession()
                        showResults = true
                    } label: {
                        Text(isEnglish ? "STOP" : "終了")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 14)
                            .background(.red.opacity(0.8))
                            .cornerRadius(12)
                    }
                }
                .padding(.bottom, 40)
            }

            // Saved message
            if let msg = composer.savedMessage {
                VStack {
                    Spacer()
                    Text(msg)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(.black.opacity(0.7))
                        .cornerRadius(8)
                        .padding(.bottom, 100)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                composer.savedMessage = nil
                            }
                        }
                }
            }
        }
    }

    private func lastPunchView(punch: PunchType) -> some View {
        VStack(spacing: 6) {
            Text(isEnglish ? punch.rawValue.uppercased() : punch.jaName)
                .font(.system(size: 32, weight: .black, design: .monospaced))
                .foregroundColor(.white)

            // Power bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.white.opacity(0.15))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(powerColor)
                        .frame(width: geo.size.width * min(detector.lastPunchPower / 100, 1))
                }
            }
            .frame(width: 200, height: 10)

            Text(String(format: "PWR %.0f%%", detector.lastPunchPower))
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundColor(powerColor)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 24)
        .background(.black.opacity(0.5))
        .cornerRadius(12)
    }

    // MARK: - Results

    private var resultsView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(isEnglish ? "SESSION RESULTS" : "セッション結果")
                    .font(.system(size: 28, weight: .black, design: .monospaced))
                    .foregroundColor(.red)
                    .padding(.top, 60)

                // Grade
                VStack(spacing: 4) {
                    Text(detector.stats.rating.grade)
                        .font(.system(size: 80, weight: .black, design: .monospaced))
                        .foregroundColor(gradeColor)
                    Text(detector.stats.rating.title)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(gradeColor.opacity(0.8))
                }
                .padding(.vertical, 10)

                // Stats grid
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    statCard(isEnglish ? "Punches" : "パンチ数", "\(detector.stats.totalPunches)")
                    statCard("PPM", String(format: "%.0f", detector.stats.punchesPerMinute))
                    statCard(isEnglish ? "Avg Power" : "平均パワー", String(format: "%.0f%%", detector.stats.avgPower))
                    statCard(isEnglish ? "Max Power" : "最大パワー", String(format: "%.0f%%", detector.stats.maxPower))
                    statCard(isEnglish ? "Duration" : "時間", durationText)
                    statCard(isEnglish ? "Form" : "フォーム", String(format: "%.0f%%", detector.stats.formScore.overall))
                }
                .padding(.horizontal, 20)

                // Rating breakdown
                VStack(spacing: 12) {
                    Text(isEnglish ? "RATING" : "レーティング")
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(.red)

                    ratingRow(isEnglish ? "Speed" : "スピード", detector.stats.rating.speed)
                    ratingRow(isEnglish ? "Power" : "パワー", detector.stats.rating.power)
                    ratingRow(isEnglish ? "Technique" : "テクニック", detector.stats.rating.technique)
                    ratingRow(isEnglish ? "Rhythm" : "リズム", detector.stats.rating.rhythm)
                    ratingRow(isEnglish ? "Combination" : "コンビ", detector.stats.rating.combination)
                }
                .padding(20)
                .background(Color.white.opacity(0.05))
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Form breakdown
                VStack(spacing: 12) {
                    Text(isEnglish ? "FORM" : "フォーム")
                        .font(.system(size: 18, weight: .black, design: .monospaced))
                        .foregroundColor(.red)

                    ratingRow(isEnglish ? "Guard" : "ガード", detector.stats.formScore.guardScore)
                    ratingRow(isEnglish ? "Stance" : "スタンス", detector.stats.formScore.stanceScore)
                    ratingRow(isEnglish ? "Rotation" : "回転", detector.stats.formScore.rotationScore)
                    ratingRow(isEnglish ? "Chin Tuck" : "顎の引き", detector.stats.formScore.chinScore)
                }
                .padding(20)
                .background(Color.white.opacity(0.05))
                .cornerRadius(16)
                .padding(.horizontal, 20)

                // Punch breakdown
                if !detector.stats.punchCounts.isEmpty {
                    VStack(spacing: 12) {
                        Text(isEnglish ? "PUNCH TYPES" : "パンチ種別")
                            .font(.system(size: 18, weight: .black, design: .monospaced))
                            .foregroundColor(.red)

                        ForEach(Array(detector.stats.punchCounts.sorted { $0.value > $1.value }), id: \.key.rawValue) { type, count in
                            HStack {
                                Text(isEnglish ? type.rawValue : type.jaName)
                                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white)
                                Spacer()
                                Text("\(count)")
                                    .font(.system(size: 20, weight: .black, design: .monospaced))
                                    .foregroundColor(.red)
                            }
                        }
                    }
                    .padding(20)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(16)
                    .padding(.horizontal, 20)
                }

                // Restart button
                Button {
                    showResults = false
                } label: {
                    Text(isEnglish ? "NEW SESSION" : "新しいセッション")
                        .font(.system(size: 20, weight: .black, design: .monospaced))
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(.red)
                        .cornerRadius(16)
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
    }

    private func statCard(_ label: String, _ value: String) -> some View {
        VStack(spacing: 6) {
            Text(value)
                .font(.system(size: 28, weight: .black, design: .monospaced))
                .foregroundColor(.white)
            Text(label)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .background(Color.white.opacity(0.05))
        .cornerRadius(12)
    }

    private func ratingRow(_ label: String, _ value: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 100, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(colorForScore(value))
                        .frame(width: geo.size.width * min(value / 100, 1))
                }
            }
            .frame(height: 8)

            Text(String(format: "%.0f", value))
                .font(.system(size: 16, weight: .black, design: .monospaced))
                .foregroundColor(colorForScore(value))
                .frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: - Helpers

    private var durationText: String {
        let mins = Int(detector.stats.duration) / 60
        let secs = Int(detector.stats.duration) % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private var powerColor: Color {
        switch detector.lastPunchPower {
        case 80...: return .red
        case 60..<80: return .orange
        case 40..<60: return .yellow
        default: return .green
        }
    }

    private var gradeColor: Color {
        colorForScore(detector.stats.rating.overall)
    }

    private func colorForScore(_ score: Double) -> Color {
        switch score {
        case 90...: return Color(red: 0.3, green: 1, blue: 0.5)
        case 80..<90: return Color(red: 0.5, green: 1, blue: 0.8)
        case 70..<80: return .yellow
        case 60..<70: return .orange
        default: return Color(red: 1, green: 0.4, blue: 0.4)
        }
    }
}

// MARK: - Skeleton Overlay

struct SkeletonOverlay: View {
    let pose: BodyPose

    private let connections: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
        (.leftShoulder, .rightShoulder), (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip), (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle),
        (.nose, .neck), (.neck, .leftShoulder), (.neck, .rightShoulder),
    ]

    var body: some View {
        Canvas { context, size in
            // Lines
            for (from, to) in connections {
                guard let p1 = pose.point(from), let p2 = pose.point(to) else { continue }
                let sp1 = CGPoint(x: p1.x * size.width, y: p1.y * size.height)
                let sp2 = CGPoint(x: p2.x * size.width, y: p2.y * size.height)
                var path = Path()
                path.move(to: sp1)
                path.addLine(to: sp2)
                context.stroke(path, with: .color(.red.opacity(0.7)), lineWidth: 3)
            }
            // Joints
            for (_, point) in pose.joints {
                let sp = CGPoint(x: point.x * size.width, y: point.y * size.height)
                let rect = CGRect(x: sp.x - 5, y: sp.y - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: rect), with: .color(.red))
                context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
            }
        }
    }
}
