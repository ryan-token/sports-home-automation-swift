//
//  main.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/2/25.
//

import AsyncHTTPClient
import AWSLambdaRuntime
import AWSLambdaEvents
import CloudSDK
import Foundation
import Models
import SharedUtils
import SotoDynamoDB

let awsClient = AWSClient()
let dynamodb = DynamoDB(client: awsClient, region: .useast1)

let runtime = LambdaRuntime { (event: SQSEvent, context: LambdaContext) async throws -> Bool in
    context.logger.info("Received SQS event: \(event)")

    let ncaaApiHost = "ncaa-api.henrygd.me" // from https://github.com/henrygd/ncaa-api
    let nflScoresUrl = "https://site.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard"
    let ncaaFootballScoresUrl = "https://\(ncaaApiHost)/scoreboard/football/fbs"
    let mensBasketballScoresUrl = "https://\(ncaaApiHost)/scoreboard/basketball-men/d1"
    let womensBasketballScoresUrl = "https://\(ncaaApiHost)/scoreboard/basketball-women/d1"

    guard isFootballSeason || isBasketballSeason else {
        context.logger.info("Not currently football or basketball season, exiting")
        return false
    }

    if isFootballSeason {
        // Check active NCAA and NFL scores for every monitored football team
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await pollNCAAScores(sport: .cfb, url: ncaaFootballScoresUrl, context: context)
            }
            group.addTask {
                try await pollNFLScores(url: nflScoresUrl, context: context)
            }
            try await group.waitForAll()
        }
    }

    if isBasketballSeason {
        // Check active NCAA scores for every monitored men's and women's basketball team
        try await withThrowingTaskGroup { group in
            group.addTask {
                try await pollNCAAScores(sport: .mbb, url: mensBasketballScoresUrl, context: context)
            }
            group.addTask {
                try await pollNCAAScores(sport: .wbb, url: womensBasketballScoresUrl, context: context)
            }
            try await group.waitForAll()
        }
    }

    return true
}

try await runtime.run()
try await awsClient.shutdown()


// MARK: Poller Utilities

private func pollNCAAScores(sport: Sport, url: String, context: LambdaContext) async throws {
    let teams = MonitoredTeam.monitoring(sport)
    guard !teams.isEmpty else { return }

    context.logger.info("Checking NCAA \(sport.rawValue) scores...")
    guard let scores = await fetchScores(NCAAGameScoresResponse.self, from: url, context: context) else { return }
    context.logger.info("Received scores for \(scores.games.count) \(sport.rawValue) games")

    // If two monitored teams play each other, the first listed claims the game
    var claimedGameIds: Set<String> = []
    for team in teams {
        guard let game = scores.games.map(\.game).first(where: { $0.home.names.short == team.name || $0.away.names.short == team.name }) else {
            context.logger.info("\(team.name) \(sport.rawValue) is not playing right now")
            continue
        }
        guard claimedGameIds.insert(game.gameID).inserted else {
            context.logger.info("\(team.name) \(sport.rawValue) game \(game.title) is already tracked for the other team in it")
            continue
        }
        context.logger.info("Found \(team.name) \(sport.rawValue) game: \(game.title)")
        try await writeNCAAGameStatusToDynamoDB(game: game, team: team, sport: sport, context: context)
    }
}

private func pollNFLScores(url: String, context: LambdaContext) async throws {
    let teams = MonitoredTeam.monitoring(.nfl)
    guard !teams.isEmpty else { return }

    context.logger.info("Checking NFL scores...")
    guard let scores = await fetchScores(NFLGameScoresResponse.self, from: url, context: context) else { return }
    context.logger.info("Received scores for \(scores.events.count) nfl games")

    var claimedGameIds: Set<String> = []
    for team in teams {
        guard let event = scores.events.first(where: { $0.competitions.first?.competitors.contains { $0.team.name == team.name } ?? false }) else {
            context.logger.info("The \(team.name) are not playing right now")
            continue
        }
        guard claimedGameIds.insert(event.id).inserted else {
            context.logger.info("\(team.name) game \(event.shortName) is already tracked for the other team in it")
            continue
        }
        context.logger.info("Found \(team.name) game: \(event.shortName)")
        try await writeNFLGameStatusToDynamoDB(event: event, team: team, context: context)
    }
}

private func fetchScores<Response: Decodable>(_ type: Response.Type, from url: String, context: LambdaContext) async -> Response? {
    var request = HTTPClientRequest(url: url)
    request.headers.add(name: "Accept", value: "application/json")
    // ESPN's CDN returns 403 for requests without a recognized HTTP client User-Agent
    request.headers.add(name: "User-Agent", value: "AsyncHTTPClient")

    do {
        context.logger.info("Making GET request to \(url)")
        let response = try await HTTPClient.shared.execute(request, timeout: .seconds(30))

        guard response.status == .ok else {
            context.logger.error("GET \(url) failed with status: \(response.status)")
            return nil
        }

        let body = try await response.body.collect(upTo: 10 * 1024 * 1024) // 10 MB
        return try JSONDecoder().decode(Response.self, from: Data(body.readableBytesView))
    } catch {
        context.logger.error("GET \(url) failed: \(error)")
        return nil
    }
}

private func writeNCAAGameStatusToDynamoDB(game: Game, team: MonitoredTeam, sport: Sport, context: LambdaContext) async throws {
    let isHome = game.home.names.short == team.name
    let mine = isHome ? game.home : game.away
    let opponent = isHome ? game.away : game.home

    let gameItem = GameItem(
        gameId: game.gameID,
        sport: sport.rawValue,
        myTeam: team.name,
        myTeamScore: Int(mine.score) ?? 0,
        opposingTeam: opponent.names.short,
        opposingTeamScore: Int(opponent.score) ?? 0,
        gamePeriod: game.currentPeriod
    )
    context.logger.info("NCAA GameItem created as \(gameItem)")
    try await writeGameItemToDynamoDB(gameItem, context: context)
}

private func writeNFLGameStatusToDynamoDB(event: Event, team: MonitoredTeam, context: LambdaContext) async throws {
    let competition = event.competitions.first
    let mine = competition?.competitors.first(where: { $0.team.name == team.name })
    let opponent = competition?.competitors.first(where: { $0.team.name != team.name })

    let gameItem = GameItem(
        gameId: event.id,
        sport: Sport.nfl.rawValue,
        myTeam: team.name,
        myTeamScore: Int(mine?.score ?? "") ?? 0,
        opposingTeam: opponent?.team.name ?? "",
        opposingTeamScore: Int(opponent?.score ?? "") ?? 0,
        gamePeriod: competition?.status.type.name ?? ""
    )
    context.logger.info("NFL GameItem created as \(gameItem)")
    try await writeGameItemToDynamoDB(gameItem, context: context)
}

private func writeGameItemToDynamoDB(_ gameItem: GameItem, context: LambdaContext) async throws {
    guard let scoresTableName = Cloud.env("DYNAMODB_SCORES_NAME") else {
        context.logger.error("DYNAMODB_SCORES_NAME environment variable not set")
        return
    }

    let dynamoItem: [String: DynamoDB.AttributeValue] = [
        "gameId": .s(gameItem.gameId),
        "sport": .s(gameItem.sport),
        "myTeam": .s(gameItem.myTeam),
        "myTeamScore": .n(String(gameItem.myTeamScore)),
        "opposingTeam": .s(gameItem.opposingTeam),
        "opposingTeamScore": .n(String(gameItem.opposingTeamScore)),
        "gamePeriod": .s(gameItem.gamePeriod)
    ]
    context.logger.info("DynamoItem created as \(dynamoItem)")

    let ddbInput = DynamoDB.PutItemInput(
        item: dynamoItem,
        tableName: scoresTableName
    )

    do {
        _ = try await dynamodb.putItem(ddbInput)
        context.logger.info("Successfully wrote game info to DynamoDB")
    } catch {
        context.logger.error("Error writing game info to DynamoDB: \(error)")
    }
}
