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
        // Check active NCAA and NFL scores for Tulsa and/or Eagles football games
        try await withThrowingTaskGroup { group in
            group.addTask {
                context.logger.info("Checking NCAA football scores...")
                if let ncaaFootballScores = await fetchScores(NCAAGameScoresResponse.self, from: ncaaFootballScoresUrl, context: context) {
                    context.logger.info("Received scores for \(ncaaFootballScores.games.count) cfb games")
                    if let tulsaFootballGame = getTulsaGameFromAPI(ncaaScores: ncaaFootballScores) {
                        context.logger.info("Found Tulsa football game: \(tulsaFootballGame.title)")
                        try await writeNCAAGameStatusToDynamoDB(tulsaGame: tulsaFootballGame, sport: .cfb, context: context)
                    } else {
                        context.logger.info("Tulsa FB is not playing right now")
                    }
                }
            }

            group.addTask {
                context.logger.info("Checking NFL football scores...")
                if let nflScores = await fetchScores(NFLGameScoresResponse.self, from: nflScoresUrl, context: context) {
                    context.logger.info("Received scores for \(nflScores.events.count) nfl games")
                    if let eaglesGame = getEaglesGameFromAPI(nflScores: nflScores) {
                        context.logger.info("Found Eagles game: \(eaglesGame.shortName)")
                        try await writeNFLGameStatusToDynamoDB(eaglesGame: eaglesGame, context: context)
                    } else {
                        context.logger.info("The Eagles are not playing right now")
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    if isBasketballSeason {
        // Check active NCAA scores for Tulsa men's & women's basketball games
        try await withThrowingTaskGroup { group in
            group.addTask {
                context.logger.info("Checking NCAA basketball scores...")
                if let mensBasketballScores = await fetchScores(NCAAGameScoresResponse.self, from: mensBasketballScoresUrl, context: context) {
                    context.logger.info("Received scores for \(mensBasketballScores.games.count) mbb games")
                    if let tulsaMbbGame = getTulsaGameFromAPI(ncaaScores: mensBasketballScores) {
                        context.logger.info("Found Tulsa men's basketball game: \(tulsaMbbGame.title)")
                        try await writeNCAAGameStatusToDynamoDB(tulsaGame: tulsaMbbGame, sport: .mbb, context: context)
                    } else {
                        context.logger.info("Tulsa MBB is not playing right now")
                    }
                }
            }

            group.addTask {
                if let womensBasketballScores = await fetchScores(NCAAGameScoresResponse.self, from: womensBasketballScoresUrl, context: context) {
                    context.logger.info("Received scores for \(womensBasketballScores.games.count) wbb games")
                    if let tulsaWbbGame = getTulsaGameFromAPI(ncaaScores: womensBasketballScores) {
                        context.logger.info("Found Tulsa women's basketball game: \(tulsaWbbGame.title)")
                        try await writeNCAAGameStatusToDynamoDB(tulsaGame: tulsaWbbGame, sport: .wbb, context: context)
                    } else {
                        context.logger.info("Tulsa WBB is not playing right now")
                    }
                }
            }

            try await group.waitForAll()
        }
    }

    return true
}

try await runtime.run()
try await awsClient.shutdown()


// MARK: Poller Utilities

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

private func getTulsaGameFromAPI(ncaaScores: NCAAGameScoresResponse) -> Game? {
    ncaaScores.games.first(where: { $0.game.title.contains("Tulsa") })?.game
}

private func getEaglesGameFromAPI(nflScores: NFLGameScoresResponse) -> Event? {
    nflScores.events.first(where: { $0.name.contains("Eagles") })
}

private func writeNCAAGameStatusToDynamoDB(tulsaGame: Game, sport: Sport, context: LambdaContext) async throws {
    guard let scoresTableName = Cloud.env("DYNAMODB_SCORES_NAME") else {
        context.logger.error("DYNAMODB_SCORES_NAME environment variable not set")
        return
    }

    let homeTeam = tulsaGame.home.names.short

    var tulsaScore = "0"
    var opposingTeamScore = "0"
    var opposingTeam = ""
    if homeTeam == "Tulsa" {
        tulsaScore = tulsaGame.home.score
        opposingTeamScore = tulsaGame.away.score
        opposingTeam = tulsaGame.away.names.short
    } else {
        tulsaScore = tulsaGame.away.score
        opposingTeamScore = tulsaGame.home.score
        opposingTeam = tulsaGame.home.names.short
    }

    let gameItem = GameItem(
        gameId: tulsaGame.gameID,
        sport: sport.rawValue,
        myTeam: "Tulsa",
        myTeamScore: Int(tulsaScore) ?? 0,
        opposingTeam: opposingTeam,
        opposingTeamScore: Int(opposingTeamScore) ?? 0,
        gamePeriod: tulsaGame.currentPeriod
    )
    context.logger.info("NCAA GameItem created as \(gameItem)")

    let dynamoItem: [String: DynamoDB.AttributeValue] = [
        "gameId": .s(gameItem.gameId),
        "sport": .s(gameItem.sport),
        "myTeam": .s(gameItem.myTeam),
        "myTeamScore": .n(String(gameItem.myTeamScore)),
        "opposingTeam": .s(gameItem.opposingTeam),
        "opposingTeamScore": .n(String(gameItem.opposingTeamScore)),
        "gamePeriod": .s(gameItem.gamePeriod)
    ]
    context.logger.info("NCAA DynamoItem created as \(dynamoItem)")

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

private func writeNFLGameStatusToDynamoDB(eaglesGame: Event, context: LambdaContext) async throws {
    guard let scoresTableName = Cloud.env("DYNAMODB_SCORES_NAME") else {
        context.logger.error("DYNAMODB_SCORES_NAME environment variable not set")
        return
    }

    let competition = eaglesGame.competitions.first
    let homeCompetitor = competition?.competitors.first(where: { $0.homeAway == "home" })
    let awayCompetitor = competition?.competitors.first(where: { $0.homeAway == "away" })

    var eaglesScore = "0"
    var opposingTeamScore = "0"
    var opposingTeam = ""

    if homeCompetitor?.team.name == "Eagles" {
        eaglesScore = homeCompetitor?.score ?? "0"
        opposingTeamScore = awayCompetitor?.score ?? "0"
        opposingTeam = awayCompetitor?.team.name ?? ""
    } else {
        eaglesScore = awayCompetitor?.score ?? "0"
        opposingTeamScore = homeCompetitor?.score ?? "0"
        opposingTeam = homeCompetitor?.team.name ?? ""
    }

    let gameItem = GameItem(
        gameId: eaglesGame.id,
        sport: "nfl",
        myTeam: "Eagles",
        myTeamScore: Int(eaglesScore) ?? 0,
        opposingTeam: opposingTeam,
        opposingTeamScore: Int(opposingTeamScore) ?? 0,
        gamePeriod: competition?.status.type.name ?? ""
    )
    context.logger.info("NFL GameItem created as \(gameItem)")

    let dynamoItem: [String: DynamoDB.AttributeValue] = [
        "gameId": .s(gameItem.gameId),
        "sport": .s(gameItem.sport),
        "myTeam": .s(gameItem.myTeam),
        "myTeamScore": .n(String(gameItem.myTeamScore)),
        "opposingTeam": .s(gameItem.opposingTeam),
        "opposingTeamScore": .n(String(gameItem.opposingTeamScore)),
        "gamePeriod": .s(gameItem.gamePeriod)
    ]
    context.logger.info("NFL DynamoItem created as \(dynamoItem)")

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

enum Sport: String {
    case cfb = "cfb"
    case mbb = "mbb"
    case wbb = "wbb"
    case nfl = "nfl"
}
