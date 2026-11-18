//
//  main.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/5/25.
//

import AWSLambdaRuntime
import AWSLambdaEvents
import CloudSDK
import Foundation
import SharedUtils
import SotoSQS

struct SportsApiCronJob: CloudwatchDetail {
    static let name = "sports-api-cron-job"
}

let client = AWSClient()
// Well inside the 10-second Lambda timeout, so a slow SQS is logged instead of killing the invocation
let sqs = SQS(client: client, region: .useast1, timeout: .seconds(5))

let runtime = LambdaRuntime { (event: SportsApiCronJob, context: LambdaContext) async throws -> Bool in
    context.logger.info("Received cron event: \(event)")

    guard isFootballSeason || isBasketballSeason else {
        context.logger.info("Not currently football or basketball season, exiting")
        return false
    }

    guard let queueUrl = Cloud.env("QUEUE_SPORTS_API_POLLER_QUEUE_URL") else {
        context.logger.error("QUEUE_SPORTS_API_POLLER_QUEUE_URL environment variable not set")
        return false
    }

    // One poll every 10 seconds across the minute, sent in a single batch request
    let polls = (0..<6).map { index in
        SQS.SendMessageBatchRequestEntry(delaySeconds: index * 10, id: "poll-\(index)", messageBody: "Check sports scores")
    }

    do {
        let response = try await sqs.sendMessageBatch(.init(entries: polls, queueUrl: queueUrl))
        let failures = response.failed ?? []
        for failure in failures {
            context.logger.error("Failed to queue \(failure.id): \(failure.code) \(failure.message ?? "")")
        }
        context.logger.info("Queued \(polls.count - failures.count) of \(polls.count) polls")
        return failures.isEmpty
    } catch {
        context.logger.error("Failed to queue polls: \(error)")
        return false
    }
}

try await runtime.run()
try await client.shutdown()
