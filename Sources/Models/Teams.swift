//
//  Teams.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 9/21/26.
//

// The teams this project follows. To follow a different team, edit `MonitoredTeam.all`; the Poller and ScoreProcessor
// both read it, so nothing else needs to change.
//
// `name` is how the sports API names the team: `names.short` on the NCAA scoreboard ("Tulsa", "Missouri") and
// `team.name` on ESPN's NFL scoreboard ("Eagles"). It is also what the Poller stores as `myTeam` in DynamoDB.
// When two listed teams play each other, the one listed first is treated as "my team" for that game.

public struct MonitoredTeam: Sendable {
    public let name: String
    public let sports: Set<Sport>
    public let colors: TeamColors

    public static let all: [MonitoredTeam] = [
        MonitoredTeam(name: "Tulsa", sports: [.cfb, .mbb, .wbb], colors: TeamColors(primary: .gold, secondary: .blue)),
        MonitoredTeam(name: "Missouri", sports: [.cfb], colors: TeamColors(primary: .gold, secondary: .black)),
        MonitoredTeam(name: "Eagles", sports: [.nfl], colors: TeamColors(primary: .midnightGreen, secondary: .silver)),
    ]

    public static func named(_ name: String) -> MonitoredTeam? {
        all.first { $0.name == name }
    }

    public static func monitoring(_ sport: Sport) -> [MonitoredTeam] {
        all.filter { $0.sports.contains(sport) }
    }
}

public enum Sport: String, Sendable {
    case cfb
    case mbb
    case wbb
    case nfl

    public var isFootball: Bool {
        self == .cfb || self == .nfl
    }
}

public struct TeamColors: Sendable {
    public let primary: LightColor
    public let secondary: LightColor

    public init(primary: LightColor, secondary: LightColor) {
        self.primary = primary
        self.secondary = secondary
    }
}

public struct LightColor: Sendable {
    // nil leaves the light on whatever color it is already showing
    public let xy: XYColor?
    // Percent. CLIP v2 treats 0 as the lowest brightness the light supports.
    public let brightness: Double

    public init(xy: XYColor?, brightness: Double = 100) {
        self.xy = xy
        self.brightness = brightness
    }

    // CIE xy as reported by the bridge for the hue/sat values these colors were originally tuned with
    public static let gold = LightColor(xy: XYColor(x: 0.4263, y: 0.4203))
    public static let blue = LightColor(xy: XYColor(x: 0.1541, y: 0.081))
    public static let midnightGreen = LightColor(xy: XYColor(x: 0.1637, y: 0.4554))
    public static let silver = LightColor(xy: XYColor(x: 0.3718, y: 0.3757))

    // A light can't emit black. This is the darkest it gets while still on: the lowest brightness it supports.
    // It sets no color on purpose, so the fade from the other team color only dims instead of passing through a third hue.
    public static let black = LightColor(xy: nil, brightness: 0)
}

public struct XYColor: Codable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
