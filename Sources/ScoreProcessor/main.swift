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
    Sport(rawValue: game.sport)?.isFootball ?? false
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
    let teamName = gameInfo.currentGame.myTeam
    guard let team = MonitoredTeam.named(teamName) else {
        context.logger.error("\(teamName) won or scored but isn't in MonitoredTeam.all, so there are no colors to flash")
        return
    }
    context.logger.info("\(teamName) won or scored! Flashing lights \(teamName) colors...")
    try await flashLights(team.colors, context: context)
}

// MARK: Hue

// Each color change is one request to the zone's grouped_light, so the bridge switches every light at once.
// Steps are scheduled against fixed deadlines rather than after each response, so API latency can't drift the cadence.
// The lights are put back to whatever they were doing before the flash once it ends.
private func flashLights(_ colors: TeamColors, context: LambdaContext) async throws {
    guard let hueApplicationKey = try await getSSMParameterValue(parameterName: "hue-remote-username", ssm: ssm, context: context) else { return }
    guard let hueAccessToken = try await getSSMParameterValue(parameterName: "hue-access-token", ssm: ssm, context: context) else { return }
    let hue = HueClient(applicationKey: hueApplicationKey, accessToken: hueAccessToken)

    guard let zone = await hue.zone(named: gameDayZoneName, context: context) else { return }
    let previousStates = await hue.lightStates(in: zone, context: context)
    if previousStates.isEmpty {
        context.logger.warning("Couldn't read the lights in \(gameDayZoneName) before flashing, so they won't be restored afterward")
    }

    let encoder = JSONEncoder()
    let bodies = try [colors.primary, colors.secondary].map { color in
        try encoder.encode(GroupedLightUpdate(color: color, transition: flashTransition))
    }
    let path = "grouped_light/\(zone.groupedLightId)"

    // The first change is sent on its own so an expired token or unreachable zone fails once instead of ten times.
    guard await hue.put(path, body: bodies[0], context: context) else { return }

    // The remaining changes run as child tasks, each started at its deadline, so a slow response
    // neither delays the next change nor lets the ones after it pile up into a burst.
    let clock = ContinuousClock()
    let start = clock.now
    try await withThrowingDiscardingTaskGroup { group in
        for step in 1..<flashColorChanges {
            try await clock.sleep(until: start + flashInterval * step)
            group.addTask {
                _ = await hue.put(path, body: bodies[step % 2], context: context)
            }
        }
    }

    // Let the last color hold for a full step, then put every light back the way it was
    try await clock.sleep(until: start + flashInterval * flashColorChanges)
    try await withThrowingDiscardingTaskGroup { group in
        for state in previousStates {
            group.addTask {
                await hue.restore(state, transition: flashTransition, context: context)
            }
        }
    }
}

struct HueClient: Sendable {
    let applicationKey: String
    let accessToken: String

    func zone(named name: String, context: LambdaContext) async -> GameDayZone? {
        guard let zones = await get("zone", as: ResourceList<Zone>.self, context: context) else { return nil }
        guard let zone = zones.data.first(where: { $0.metadata.name == name }) else {
            context.logger.error("No Hue zone named \(name) found")
            return nil
        }
        guard let groupedLight = zone.services.first(where: { $0.rtype == "grouped_light" }) else {
            context.logger.error("Hue zone \(name) has no grouped_light service")
            return nil
        }
        let lightIds = zone.children.filter { $0.rtype == "light" }.map(\.rid)
        return GameDayZone(groupedLightId: groupedLight.rid, lightIds: lightIds)
    }

    // A snapshot of each light in the zone, taken so the flash can be undone
    func lightStates(in zone: GameDayZone, context: LambdaContext) async -> [LightState] {
        guard let lights = await get("light", as: ResourceList<Light>.self, context: context) else { return [] }
        let states = lights.data.filter { zone.lightIds.contains($0.id) }.map(LightState.init)
        context.logger.info("Captured state of \(states.count) lights: \(states)")
        return states
    }

    func restore(_ state: LightState, transition: Duration, context: LambdaContext) async {
        let encoder = JSONEncoder()
        let path = "light/\(state.id)"
        do {
            // Color and brightness first, while the light is still on from the flash
            let restoreLook = try encoder.encode(LightUpdate(state: state, transition: transition))
            guard await put(path, body: restoreLook, context: context) else { return }
            if !state.on {
                let turnOff = try encoder.encode(LightUpdate(on: false, transition: transition))
                _ = await put(path, body: turnOff, context: context)
            }
        } catch {
            context.logger.error("Couldn't encode the restore request for \(path): \(error)")
        }
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

    // Returns whether the bridge applied the change. 207 means it accepted the request but couldn't reach
    // every light; the rest still changed, so that counts as applied.
    func put(_ path: String, body: Data, context: LambdaContext) async -> Bool {
        var request = request(.PUT, path)
        request.headers.add(name: "Content-Type", value: "application/json")
        request.body = .bytes(ByteBuffer(bytes: body))

        do {
            let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))
            switch response.status {
            case .ok:
                context.logger.info("PUT \(path) succeeded")
                return true
            case .multiStatus:
                let responseBody = try await response.body.collect(upTo: 64 * 1024)
                context.logger.warning("PUT \(path) returned 207, some lights unreachable: \(String(buffer: responseBody))")
                return true
            default:
                let responseBody = try await response.body.collect(upTo: 64 * 1024)
                context.logger.error("PUT \(path) returned \(response.status): \(String(buffer: responseBody))")
                return false
            }
        } catch {
            context.logger.error("PUT \(path) failed: \(error)")
            return false
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

struct GameDayZone: Sendable {
    let groupedLightId: String
    let lightIds: [String]
}

// What a light was doing before the flash. Color lights report both xy and mirek; mirek is only the live
// value when the light is in color temperature mode, so that is the one to restore in that case.
struct LightState: Sendable {
    let id: String
    let on: Bool
    let brightness: Double?
    let xy: XYColor?
    let mirek: Int?

    init(_ light: Light) {
        id = light.id
        on = light.on.on
        brightness = light.dimming?.brightness
        if let colorTemperature = light.colorTemperature, colorTemperature.mirekValid, let mirek = colorTemperature.mirek {
            self.mirek = mirek
            xy = nil
        } else {
            mirek = nil
            xy = light.color?.xy
        }
    }
}

// MARK: Hue CLIP v2 resources

struct ResourceList<Resource: Decodable>: Decodable {
    let data: [Resource]
}

struct ResourceReference: Decodable {
    let rid: String
    let rtype: String
}

struct Zone: Decodable {
    struct Metadata: Decodable {
        let name: String
    }

    let metadata: Metadata
    let children: [ResourceReference]
    let services: [ResourceReference]
}

struct Light: Decodable {
    struct On: Decodable {
        let on: Bool
    }

    struct Dimming: Decodable {
        let brightness: Double
    }

    struct Color: Decodable {
        let xy: XYColor
    }

    struct ColorTemperature: Decodable {
        let mirek: Int?
        let mirekValid: Bool

        enum CodingKeys: String, CodingKey {
            case mirek
            case mirekValid = "mirek_valid"
        }
    }

    let id: String
    let on: On
    let dimming: Dimming?
    let color: Color?
    let colorTemperature: ColorTemperature?

    enum CodingKeys: String, CodingKey {
        case id, on, dimming, color
        case colorTemperature = "color_temperature"
    }
}

// Body for PUT /route/clip/v2/resource/grouped_light/{id}. `color` is left out when the step only changes brightness.
struct GroupedLightUpdate: Encodable {
    struct On: Encodable {
        let on = true
    }

    struct Dimming: Encodable {
        let brightness: Double
    }

    struct Color: Encodable {
        let xy: XYColor
    }

    struct Dynamics: Encodable {
        let duration: Int
    }

    let on = On()
    let dimming: Dimming
    let color: Color?
    let dynamics: Dynamics

    init(color: LightColor, transition: Duration) {
        dimming = Dimming(brightness: color.brightness)
        self.color = color.xy.map(Color.init)
        dynamics = Dynamics(duration: Int(transition / .milliseconds(1)))
    }
}

// Body for PUT /route/clip/v2/resource/light/{id}. Only the fields that are set are sent.
struct LightUpdate: Encodable {
    struct On: Encodable {
        let on: Bool
    }

    struct Dimming: Encodable {
        let brightness: Double
    }

    struct Color: Encodable {
        let xy: XYColor
    }

    struct ColorTemperature: Encodable {
        let mirek: Int
    }

    struct Dynamics: Encodable {
        let duration: Int
    }

    var on: On?
    var dimming: Dimming?
    var color: Color?
    var colorTemperature: ColorTemperature?
    let dynamics: Dynamics

    enum CodingKeys: String, CodingKey {
        case on, dimming, color, dynamics
        case colorTemperature = "color_temperature"
    }

    init(state: LightState, transition: Duration) {
        dimming = state.brightness.map(Dimming.init)
        color = state.xy.map(Color.init)
        colorTemperature = state.mirek.map(ColorTemperature.init)
        dynamics = Dynamics(duration: Int(transition / .milliseconds(1)))
    }

    init(on: Bool, transition: Duration) {
        self.on = On(on: on)
        dynamics = Dynamics(duration: Int(transition / .milliseconds(1)))
    }
}
