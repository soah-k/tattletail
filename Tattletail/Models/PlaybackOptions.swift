import Foundation

/// User-tunable options that control how a recording is replayed.
struct PlaybackOptions: Codable, Sendable, Equatable {
    /// Playback speed multiplier. 1.0 = as recorded; 2.0 = twice as fast.
    var speed: Double
    /// Number of times to play through. Ignored when `loops` is true.
    var repeatCount: Int
    /// When true, replay repeats until the user stops it.
    var loops: Bool
    /// Skip the recorded cursor path (pure moves) and jump straight between
    /// clicks — much faster, at the cost of the natural pointer motion.
    var jumpInstantly: Bool
    /// Add slight random variation to the timing between steps, for more
    /// natural-looking playback.
    var humanize: Bool

    init(speed: Double = 1.0, repeatCount: Int = 1, loops: Bool = false,
         jumpInstantly: Bool = false, humanize: Bool = false) {
        self.speed = speed
        self.repeatCount = max(1, repeatCount)
        self.loops = loops
        self.jumpInstantly = jumpInstantly
        self.humanize = humanize
    }

    enum CodingKeys: String, CodingKey {
        case speed, repeatCount, loops, jumpInstantly, humanize
    }

    /// Tolerant decoding so older files (which lack the newer flags) still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? 1.0
        self.repeatCount = max(1, try c.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1)
        self.loops = try c.decodeIfPresent(Bool.self, forKey: .loops) ?? false
        self.jumpInstantly = try c.decodeIfPresent(Bool.self, forKey: .jumpInstantly) ?? false
        self.humanize = try c.decodeIfPresent(Bool.self, forKey: .humanize) ?? false
    }

    static let `default` = PlaybackOptions()

    /// Discrete speed steps offered as quick presets in the UI.
    static let speedChoices: [Double] = [0.25, 0.5, 1.0, 2.0, 4.0]

    /// Bounds for the fine-grained speed slider.
    static let minSpeed: Double = 0.25
    static let maxSpeed: Double = 8.0

    /// Lowest allowed delay between two events, regardless of speed, so we never
    /// outrun the window server.
    static let minimumInterEventDelay: TimeInterval = 0.0005
}
