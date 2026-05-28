import Foundation
import Vision

// MARK: - Punch Types

enum PunchType: String {
    case jab = "Jab"
    case cross = "Cross"
    case hookLeft = "L-Hook"
    case hookRight = "R-Hook"
    case uppercut = "Uppercut"

    var jaName: String {
        switch self {
        case .jab: return "ジャブ"
        case .cross: return "ストレート"
        case .hookLeft: return "左フック"
        case .hookRight: return "右フック"
        case .uppercut: return "アッパー"
        }
    }
}

// MARK: - Punch Record

struct PunchRecord {
    let type: PunchType
    let power: Double      // 0-100
    let speed: Double      // normalized wrist velocity
    let timestamp: Date
}

// MARK: - Form Score

struct BoxingFormScore {
    var guardScore: Double = 0      // hands up protecting face
    var stanceScore: Double = 0     // feet shoulder-width, proper stance
    var rotationScore: Double = 0   // hip/shoulder rotation on punches
    var chinScore: Double = 0       // chin tucked
    var overall: Double { (guardScore + stanceScore + rotationScore + chinScore) / 4 }
}

// MARK: - Boxer Rating

struct BoxerRating {
    var speed: Double = 0          // punch frequency & velocity
    var power: Double = 0          // estimated punch power
    var technique: Double = 0      // form correctness
    var rhythm: Double = 0         // consistency of timing
    var combination: Double = 0    // multi-punch sequences

    var overall: Double { (speed + power + technique + rhythm + combination) / 5 }

    var grade: String {
        switch overall {
        case 90...: return "S"
        case 80..<90: return "A"
        case 70..<80: return "B"
        case 60..<70: return "C"
        default: return "D"
        }
    }

    var title: String {
        let en = Locale.preferredLanguages.first?.hasPrefix("en") == true
        switch overall {
        case 90...: return en ? "Champion" : "チャンピオン"
        case 80..<90: return en ? "Contender" : "コンテンダー"
        case 70..<80: return en ? "Fighter" : "ファイター"
        case 60..<70: return en ? "Prospect" : "プロスペクト"
        case 40..<60: return en ? "Rookie" : "ルーキー"
        default: return en ? "Beginner" : "ビギナー"
        }
    }
}

// MARK: - Body Pose

struct BodyPose {
    var joints: [VNHumanBodyPoseObservation.JointName: CGPoint] = [:]

    func point(_ joint: VNHumanBodyPoseObservation.JointName) -> CGPoint? {
        joints[joint]
    }

    func angle(a: VNHumanBodyPoseObservation.JointName,
               b: VNHumanBodyPoseObservation.JointName,
               c: VNHumanBodyPoseObservation.JointName) -> Double? {
        guard let pA = joints[a], let pB = joints[b], let pC = joints[c] else { return nil }
        let v1 = CGVector(dx: pA.x - pB.x, dy: pA.y - pB.y)
        let v2 = CGVector(dx: pC.x - pB.x, dy: pC.y - pB.y)
        let dot = v1.dx * v2.dx + v1.dy * v2.dy
        let mag1 = sqrt(v1.dx * v1.dx + v1.dy * v1.dy)
        let mag2 = sqrt(v2.dx * v2.dx + v2.dy * v2.dy)
        guard mag1 > 0, mag2 > 0 else { return nil }
        let cosAngle = max(-1, min(1, dot / (mag1 * mag2)))
        return acos(cosAngle) * 180 / Double.pi
    }

    var midShoulder: CGPoint? {
        guard let ls = point(.leftShoulder), let rs = point(.rightShoulder) else { return nil }
        return CGPoint(x: (ls.x + rs.x) / 2, y: (ls.y + rs.y) / 2)
    }

    var midHip: CGPoint? {
        guard let lh = point(.leftHip), let rh = point(.rightHip) else { return nil }
        return CGPoint(x: (lh.x + rh.x) / 2, y: (lh.y + rh.y) / 2)
    }
}

// MARK: - Session Stats

struct SessionStats {
    var totalPunches: Int = 0
    var punchCounts: [PunchType: Int] = [:]
    var avgPower: Double = 0
    var maxPower: Double = 0
    var punchesPerMinute: Double = 0
    var duration: TimeInterval = 0
    var formScore = BoxingFormScore()
    var rating = BoxerRating()
    var recentPunches: [PunchRecord] = []
}
