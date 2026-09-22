//
//  main.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/2/25.
//

import AsyncHTTPClient
import AWSLambdaEvents
import AWSLambdaRuntime
import Foundation
import Models
import NIOCore
import SSMUtils
import SotoSSM

// The Hue zone whose lights get flashed. Add or remove lights from it in the Hue app; nothing here needs to change.
let gameDayZoneName = "Game Day"

let flashColorChanges = 10
let flashInterval: Duration = .milliseconds(800)
let flashTransition: Duration = .milliseconds(400)

let awsClient = AWSClient()
let ssm = SSM(client: awsClient, region: .useast1)

let runtime = LambdaRuntime { (event: DynamoDBEvent, context: LambdaContext) async throws -> Bool in
    context.logger.info("Received DynamoDB event: \(event)")

    for event in event.records {
        guard let gameInfo: GameInfo = parseDynamoEventIntoGameItem(event: event, context: context) else { continue }

        if isFootballGame(game: gameInfo.currentGame) {
            if myTeamScored(gameInfo) {
                try await flashLightsAppropriateColors(gameInfo: gameInfo, context: context)
            }
        }

        if myTeamWon(gameInfo) {
            try await flashLightsAppropriateColors(gameInfo: gameInfo, context: context)
        }
    }

    return true
}

try await runtime.run()
try await awsClient.shutdown()


// MARK: ScoreProcessor Utilities

private func isFootballGame(game: GameItem) -> Bool {
    game.sport == "cfb" || game.sport == "nfl"
}

private func parseDynamoEventIntoGameItem(event: DynamoDBEvent.EventRecord, context: LambdaContext) -> GameInfo? {
    guard let oldImage = event.change.oldImage else {
        context.logger.info("No old image in record, skipping")
        return nil
    }
    guard let newImage = event.change.newImage else {
        context.logger.info("No new image in record, skipping")
        return nil
    }

    guard case .string(let gameId) = newImage["gameId"],
          case .string(let sport) = newImage["sport"],
          case .string(let myTeam) = newImage["myTeam"],
          case .number(let myTeamScore) = newImage["myTeamScore"],
          case .number(let previousMyTeamScore) = oldImage["myTeamScore"],
          case .string(let opposingTeam) = newImage["opposingTeam"],
          case .number(let opposingTeamScore) = newImage["opposingTeamScore"],
          case .string(let previousGamePeriod) = oldImage["gamePeriod"],
          case .string(let gamePeriod) = newImage["gamePeriod"] else {
        context.logger.error("Missing or invalid attributes in DynamoDB record")
        return nil
    }

    let gameItem = GameItem(
        gameId: gameId,
        sport: sport,
        myTeam: myTeam,
        myTeamScore: Int(myTeamScore) ?? 0,
        opposingTeam: opposingTeam,
        opposingTeamScore: Int(opposingTeamScore) ?? 0,
        gamePeriod: gamePeriod
    )

    context.logger.info("Processed gameItem: \(gameItem), previousGamePeriod as: \(previousGamePeriod), and previousMyTeamScore as: \(Int(previousMyTeamScore) ?? 0)")
    return GameInfo(
        currentGame: gameItem,
        previousGamePeriod: previousGamePeriod,
        previousMyTeamScore: Int(previousMyTeamScore) ?? 0
    )
}

private func myTeamScored(_ gameInfo: GameInfo) -> Bool {
    let oldMyTeamScore = gameInfo.previousMyTeamScore
    let newMyTeamScore = gameInfo.currentGame.myTeamScore

	// exclude extra points
	return newMyTeamScore - oldMyTeamScore > 1
}

private func myTeamWon(_ gameInfo: GameInfo) -> Bool {
    let myTeamScore = gameInfo.currentGame.myTeamScore
    let opposingTeamScore = gameInfo.currentGame.opposingTeamScore
    let previousGamePeriod = gameInfo.previousGamePeriod
    let currentGamePeriod = gameInfo.currentGame.gamePeriod

    let gameJustEnded = !previousGamePeriod.contains("FINAL") && currentGamePeriod.contains("FINAL")

    return gameJustEnded && myTeamScore > opposingTeamScore
}

private func flashLightsAppropriateColors(gameInfo: GameInfo, context: LambdaContext) async throws {
    switch gameInfo.currentGame.myTeam {
    case "Tulsa":
        context.logger.info("Tulsa won or scored! Flashing lights Tulsa colors...")
        try await flashLights(.tulsa, context: context)
    case "Eagles":
        context.logger.info("Eagles won or scored! Flashing lights Eagles colors...")
        try await flashLights(.eagles, context: context)
    default:
        context.logger.info("Some other team won or scored? Flashing lights Tulsa colors anyway...")
        try await flashLights(.tulsa, context: context)
    }
}

// MARK: Hue

// Each color change is one request to the zone's grouped_light, so the bridge switches every light at once.
// Steps are scheduled against fixed deadlines rather than after each response, so API latency can't drift the cadence.
private func flashLights(_ colors: TeamColors, context: LambdaContext) async throws {
    guard let hueApplicationKey = try await getSSMParameterValue(parameterName: "hue-remote-username", ssm: ssm, context: context) else { return }
    guard let hueAccessToken = try await getSSMParameterValue(parameterName: "hue-access-token", ssm: ssm, context: context) else { return }
    let hue = HueClient(applicationKey: hueApplicationKey, accessToken: hueAccessToken)

    guard let groupedLightId = await hue.groupedLightId(forZoneNamed: gameDayZoneName, context: context) else { return }

    let encoder = JSONEncoder()
    let bodies = try [colors.primary, colors.secondary].map { color in
        try encoder.encode(GroupedLightUpdate(color: color, transition: flashTransition))
    }

    let clock = ContinuousClock()
    let start = clock.now
    for step in 0..<flashColorChanges {
        try await clock.sleep(until: start + flashInterval * step)
        await hue.put("grouped_light/\(groupedLightId)", body: bodies[step % 2], context: context)
    }
}

struct HueClient: Sendable {
    let applicationKey: String
    let accessToken: String

    func groupedLightId(forZoneNamed name: String, context: LambdaContext) async -> String? {
        guard let zones = await get("zone", as: ResourceList<Zone>.self, context: context) else { return nil }
        guard let zone = zones.data.first(where: { $0.metadata.name == name }) else {
            context.logger.error("No Hue zone named \(name) found")
            return nil
        }
        guard let groupedLight = zone.services.first(where: { $0.rtype == "grouped_light" }) else {
            context.logger.error("Hue zone \(name) has no grouped_light service")
            return nil
        }
        return groupedLight.rid
    }

    func get<Resource: Decodable>(_ path: String, as type: Resource.Type, context: LambdaContext) async -> Resource? {
        do {
            let response = try await HTTPClient.shared.execute(request(.GET, path), timeout: .seconds(30))
            let body = try await response.body.collect(upTo: 1024 * 1024)
            guard response.status == .ok else {
                context.logger.error("GET \(path) failed with status \(response.status): \(String(buffer: body))")
                return nil
            }
            return try JSONDecoder().decode(Resource.self, from: Data(body.readableBytesView))
        } catch {
            context.logger.error("GET \(path) failed: \(error)")
            return nil
        }
    }

    func put(_ path: String, body: Data, context: LambdaContext) async {
        var request = request(.PUT, path)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: body))

        do {
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
            // 207 means the bridge accepted the request but couldn't reach every light
            guard response.status == .ok else {
                let responseBody = try await response.body.collect(upTo: 64 * 1024)
                context.logger.error("PUT \(path) returned \(response.status): \(String(buffer: responseBody))")
                return
            }
            context.logger.info("PUT \(path) succeeded")
        } catch {
            context.logger.error("PUT \(path) failed: \(error)")
        }
    }

    private func request(_ method: HTTPMethod, _ path: String) -> HTTPClientRequest {
        var request = HTTPClientRequest(url: "https://api.meethue.com/route/clip/v2/resource/\(path)")
        request.method = method
        request.headers.add(name: "Authorization", value: "Bearer \(accessToken)")
        request.headers.add(name: "hue-application-key", value: applicationKey)
        return request
    }
}

struct ResourceList<Resource: Decodable>: Decodable {
    let data: [Resource]
}

struct Zone: Decodable {
    struct Metadata: Decodable {
        let name: String
    }

    struct Service: Decodable {
        let rid: String
        let rtype: String
    }

    let metadata: Metadata
    let services: [Service]
}

// Body for PUT /route/clip/v2/resource/grouped_light/{id}
struct GroupedLightUpdate: Encodable {
    struct On: Encodable {
        let on = true
    }

    struct Dimming: Encodable {
        let brightness = 100.0
    }

    struct Color: Encodable {
        let xy: XYColor
    }

    struct Dynamics: Encodable {
        let duration: Int
    }

    let on = On()
    let dimming = Dimming()
    let color: Color
    let dynamics: Dynamics

    init(color: XYColor, transition: Duration) {
        self.color = Color(xy: color)
        dynamics = Dynamics(duration: Int(transition / .milliseconds(1)))
    }
}

struct TeamColors: Sendable {
    let primary: XYColor
    let secondary: XYColor

    static let tulsa = TeamColors(primary: .gold, secondary: .blue)
    static let eagles = TeamColors(primary: .midnightGreen, secondary: .silver)
}

// CIE xy as reported by the bridge for the hue/sat values these colors were originally tuned with
struct XYColor: Encodable, Sendable {
    let x: Double
    let y: Double

    static let gold = XYColor(x: 0.4263, y: 0.4203)
    static let blue = XYColor(x: 0.1541, y: 0.081)
    static let midnightGreen = XYColor(x: 0.1637, y: 0.4554)
    static let silver = XYColor(x: 0.3718, y: 0.3757)
}
