//
//  NFLGameScoresResponse.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/6/25.
//

// The response type we get from hitting ESPN's /scoreboard site API endpoint.
// Only the fields the Poller reads are modeled: ESPN's payload is large and the
// unused sections (leagues, calendar, venue, broadcasts) are not stable across the season.

public struct NFLGameScoresResponse: Decodable {
    public let events: [Event]
}

public struct Event: Decodable {
    public let id: String
    public let date: String
    public let name: String
    public let shortName: String
    public let competitions: [Competition]
}

public struct Competition: Decodable {
    public let id: String
    public let competitors: [Competitor]
    public let status: Status
}

public struct Competitor: Decodable {
    public let id: String
    public let homeAway: String
    public let team: NFLTeam
    public let score: String
}

public struct NFLTeam: Decodable {
    public let id: String
    public let name: String
    public let abbreviation: String
    public let displayName: String
}

public struct Status: Decodable {
    public let period: Int
    public let type: StatusType
}

public struct StatusType: Decodable {
    public let name: String
    public let state: String
    public let completed: Bool
}
