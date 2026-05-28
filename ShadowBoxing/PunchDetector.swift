import Foundation
import Vision
import QuartzCore

@Observable
final class PunchDetector {
    var stats = SessionStats()
    var lastPunchType: PunchType?
    var lastPunchPower: Double = 0
    var isSessionActive = false
    var isFrontCamera = true  // front camera flips left/right

    private var prevLeftWrist: CGPoint?
    private var prevRightWrist: CGPoint?
    private var prevLeftElbow: CGPoint?
    private var prevRightElbow: CGPoint?
    private var prevHipAngle: Double?
    private var punchCooldown: CFTimeInterval = 0
    private var lastPunchTime: CFTimeInterval = 0
    private var sessionStart: Date?
    private var allPowers: [Double] = []
    private var punchTimestamps: [Date] = []
    private var comboBuffer: [PunchType] = []
    private var lastComboTime: CFTimeInterval = 0

    private let punchThreshold: Double = 0.055  // minimum wrist movement per frame
    private let cooldownInterval: CFTimeInterval = 0.35

    // Form tracking
    private var guardSamples: [Double] = []
    private var stanceSamples: [Double] = []
    private var rotationSamples: [Double] = []
    private var chinSamples: [Double] = []

    func startSession() {
        stats = SessionStats()
        prevLeftWrist = nil
        prevRightWrist = nil
        prevLeftElbow = nil
        prevRightElbow = nil
        prevHipAngle = nil
        lastPunchTime = 0
        sessionStart = Date()
        allPowers = []
        punchTimestamps = []
        comboBuffer = []
        guardSamples = []
        stanceSamples = []
        rotationSamples = []
        chinSamples = []
        isSessionActive = true
    }

    func stopSession() {
        isSessionActive = false
        if let start = sessionStart {
            stats.duration = Date().timeIntervalSince(start)
        }
        computeRating()
    }

    func analyze(_ pose: BodyPose) {
        guard isSessionActive else { return }

        let now = CACurrentMediaTime()

        // Get key points
        let lw = pose.point(.leftWrist)
        let rw = pose.point(.rightWrist)
        let le = pose.point(.leftElbow)
        let re = pose.point(.rightElbow)
        let ls = pose.point(.leftShoulder)
        let rs = pose.point(.rightShoulder)
        let lh = pose.point(.leftHip)
        let rh = pose.point(.rightHip)
        let nose = pose.point(.nose)

        // Detect punches from wrist velocity
        // Front camera mirrors the image, so Vision's "left" = user's right
        let userLeftIsVisionLeft = !isFrontCamera
        if now - lastPunchTime >= cooldownInterval {
            if let lw = lw, let plw = prevLeftWrist {
                let vel = hypot(lw.x - plw.x, lw.y - plw.y)
                if vel > punchThreshold {
                    let isUserLeft = userLeftIsVisionLeft
                    let punchType = classifyPunch(wrist: lw, prevWrist: plw, elbow: le, shoulder: ls, isLeft: isUserLeft)
                    let power = computePower(velocity: vel, pose: pose, isLeft: isUserLeft)
                    registerPunch(type: punchType, power: power, now: now)
                }
            }
            if now - lastPunchTime >= cooldownInterval {
                if let rw = rw, let prw = prevRightWrist {
                    let vel = hypot(rw.x - prw.x, rw.y - prw.y)
                    if vel > punchThreshold {
                        let isUserLeft = !userLeftIsVisionLeft
                        let punchType = classifyPunch(wrist: rw, prevWrist: prw, elbow: re, shoulder: rs, isLeft: isUserLeft)
                        let power = computePower(velocity: vel, pose: pose, isLeft: isUserLeft)
                        registerPunch(type: punchType, power: power, now: now)
                    }
                }
            }
        }

        // Analyze form
        analyzeForm(pose: pose, lw: lw, rw: rw, ls: ls, rs: rs, lh: lh, rh: rh, nose: nose)

        // Update previous positions
        prevLeftWrist = lw
        prevRightWrist = rw
        prevLeftElbow = le
        prevRightElbow = re

        // Update duration & PPM
        if let start = sessionStart {
            stats.duration = Date().timeIntervalSince(start)
            if stats.duration > 0 {
                stats.punchesPerMinute = Double(stats.totalPunches) / (stats.duration / 60)
            }
        }
    }

    // MARK: - Punch Classification

    private func classifyPunch(wrist: CGPoint, prevWrist: CGPoint, elbow: CGPoint?, shoulder: CGPoint?, isLeft: Bool) -> PunchType {
        let dx = wrist.x - prevWrist.x
        let dy = wrist.y - prevWrist.y

        // Upward movement = uppercut
        if dy < -0.03 && abs(dx) < abs(dy) * 0.5 {
            return isLeft ? .uppercutLeft : .uppercutRight
        }

        // Horizontal movement = hook
        if abs(dx) > abs(dy) * 1.5 && abs(dx) > 0.02 {
            return isLeft ? .hookLeft : .hookRight
        }

        // Forward punch: check arm extension
        if let elbow = elbow, let shoulder = shoulder {
            let armLength = hypot(wrist.x - shoulder.x, wrist.y - shoulder.y)
            let upperArm = hypot(elbow.x - shoulder.x, elbow.y - shoulder.y)
            // Fully extended = straight
            if armLength > upperArm * 1.5 {
                return isLeft ? .straightLeft : .straightRight
            }
        }

        // Default = jab
        return isLeft ? .jabLeft : .jabRight
    }

    private func computePower(velocity: Double, pose: BodyPose, isLeft: Bool) -> Double {
        // Base power from wrist speed
        var power = min(velocity / 0.12, 1.0) * 70

        // Bonus from hip rotation
        if let lh = pose.point(.leftHip), let rh = pose.point(.rightHip),
           let ls = pose.point(.leftShoulder), let rs = pose.point(.rightShoulder) {
            let hipAngle = atan2(rh.y - lh.y, rh.x - lh.x)
            let shoulderAngle = atan2(rs.y - ls.y, rs.x - ls.x)
            let rotation = abs(hipAngle - shoulderAngle)
            power += rotation * 100 // rotation bonus
        }

        return min(power, 100)
    }

    private func registerPunch(type: PunchType, power: Double, now: CFTimeInterval) {
        lastPunchTime = now
        lastPunchType = type
        lastPunchPower = power

        stats.totalPunches += 1
        stats.punchCounts[type, default: 0] += 1

        allPowers.append(power)
        stats.avgPower = allPowers.reduce(0, +) / Double(allPowers.count)
        stats.maxPower = max(stats.maxPower, power)

        let record = PunchRecord(type: type, power: power, speed: 0, timestamp: Date())
        stats.recentPunches.append(record)
        if stats.recentPunches.count > 20 {
            stats.recentPunches.removeFirst()
        }

        punchTimestamps.append(Date())

        // Combo tracking
        if now - lastComboTime < 1.5 {
            comboBuffer.append(type)
        } else {
            comboBuffer = [type]
        }
        lastComboTime = now
    }

    // MARK: - Form Analysis

    private func analyzeForm(pose: BodyPose, lw: CGPoint?, rw: CGPoint?,
                             ls: CGPoint?, rs: CGPoint?, lh: CGPoint?, rh: CGPoint?, nose: CGPoint?) {

        // Guard: hands should be near face height
        if let lw = lw, let rw = rw, let nose = nose {
            let lDist = abs(lw.y - nose.y)
            let rDist = abs(rw.y - nose.y)
            let avgDist = (lDist + rDist) / 2
            let guardVal = max(0, min(100, (1 - avgDist / 0.2) * 100))
            guardSamples.append(guardVal)
        }

        // Stance: feet shoulder-width apart
        if let la = pose.point(.leftAnkle), let ra = pose.point(.rightAnkle),
           let ls = ls, let rs = rs {
            let feetWidth = abs(la.x - ra.x)
            let shoulderWidth = abs(ls.x - rs.x)
            let ratio = feetWidth / max(shoulderWidth, 0.01)
            // Ideal ratio around 1.0-1.3
            let stanceVal = max(0, min(100, 100 - abs(ratio - 1.15) * 200))
            stanceSamples.append(stanceVal)
        }

        // Hip rotation (shoulder vs hip line angle difference)
        if let lh = lh, let rh = rh, let ls = ls, let rs = rs {
            let hipAngle = atan2(rh.y - lh.y, rh.x - lh.x)
            let shoulderAngle = atan2(rs.y - ls.y, rs.x - ls.x)
            let rotation = abs(hipAngle - shoulderAngle)
            let rotVal = min(100, rotation * 300)
            rotationSamples.append(rotVal)
        }

        // Chin tuck: nose below mid-eye line, chin close to chest
        if let nose = nose, let neck = pose.point(.neck) {
            let chinDist = abs(nose.y - neck.y)
            let chinVal = max(0, min(100, (1 - chinDist / 0.15) * 100))
            chinSamples.append(chinVal)
        }

        // Update form score (rolling average of last 30 samples)
        let window = 30
        stats.formScore.guardScore = avg(guardSamples.suffix(window))
        stats.formScore.stanceScore = avg(stanceSamples.suffix(window))
        stats.formScore.rotationScore = avg(rotationSamples.suffix(window))
        stats.formScore.chinScore = avg(chinSamples.suffix(window))
    }

    // MARK: - Boxer Rating

    private func computeRating() {
        // Speed: based on punches per minute
        stats.rating.speed = min(100, stats.punchesPerMinute / 1.2)

        // Power: based on average power
        stats.rating.power = stats.avgPower

        // Technique: form score
        stats.rating.technique = stats.formScore.overall

        // Rhythm: consistency of punch timing
        if punchTimestamps.count > 2 {
            var intervals: [Double] = []
            for i in 1..<punchTimestamps.count {
                intervals.append(punchTimestamps[i].timeIntervalSince(punchTimestamps[i-1]))
            }
            let meanInterval = intervals.reduce(0, +) / Double(intervals.count)
            let variance = intervals.map { ($0 - meanInterval) * ($0 - meanInterval) }.reduce(0, +) / Double(intervals.count)
            let cv = sqrt(variance) / max(meanInterval, 0.01)  // coefficient of variation
            stats.rating.rhythm = max(0, min(100, (1 - cv) * 100))
        }

        // Combination: variety of punch types used
        let typesUsed = stats.punchCounts.filter { $0.value > 0 }.count
        stats.rating.combination = min(100, Double(typesUsed) / 6 * 100)
    }

    private func avg(_ values: ArraySlice<Double>) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
