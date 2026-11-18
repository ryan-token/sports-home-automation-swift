//
//  Project.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/2/25.
//

import Cloud

// EventBridge cannot do seconds, so we have EventBridge do every minute
// That EventBridge schedule triggers a scheduler function that fires off 6 SQS messages, one for every 10 seconds (via the delaySeconds SQS input option)
// Those SQS events trigger the API poller every 10 seconds, which writes relevant games to DynamoDB
// Those DynamoDB writes get streamed to the processor Lambda which can control my lights if the relevant team wins
/// The fields of Pulumi's `aws:getCallerIdentity` result that this project reads.
struct CallerIdentity {
    let accountId: String
}

@main
struct SportsHomeAutomationSwift: AWSProject {
    func build() async throws -> Outputs {
        // The account being deployed to, resolved by Pulumi at deploy time, so the
        // SSM permission ARNs below follow whichever AWS profile is active.
        let accountId = Variable<CallerIdentity>.invoke(
            name: "caller-identity",
            function: "aws:getCallerIdentity"
        ).output.accountId

        func ssmParameterARN(_ name: String) -> String {
            "arn:aws:ssm:us-east-1:\(accountId):parameter/\(name)"
        }

        // MARK: App Infrastructure

        let pollerCron = AWS.Cron(
            "sports-api-cron-job",
            schedule: .rate(.minutes(1))
        )

        let sportsApiScheduler = AWS.Function(
            "sports-api-scheduler",
            targetName: "Scheduler",
			build: .staticLinuxSDK,
			buildOptions: .stripSymbols
        )

        let sportsApiPollerQueue = AWS.Queue("sports-api-poller-queue")

        let sportsApiPoller = AWS.Function(
            "sports-api-poller-function",
            targetName: "Poller",
			build: .staticLinuxSDK,
			buildOptions: .stripSymbols
        )

        let scoresTable = AWS.DynamoDB(
            "Scores",
            primaryIndex: .init(
                partitionKey: ("gameId", .string)
            ),
            streaming: .enabled(viewType: .newAndOldImages)
        )

        let scoreProcessor = AWS.Function(
            "score-processor",
            targetName: "ScoreProcessor",
            timeout: .seconds(60),
			build: .staticLinuxSDK,
			buildOptions: .stripSymbols
        )

        pollerCron.invoke(sportsApiScheduler) // cron job triggers the scheduler Lambda
        sportsApiScheduler.link(sportsApiPollerQueue) // scheduler Lambda has write permissions to the poller SQS queue
        sportsApiPollerQueue.subscribe(sportsApiPoller) // API poller is invoked by SQS events
        sportsApiPoller.link(scoresTable) // API poller Lambda has write permissions on the 'Scores' DynamoDB table
        scoresTable.subscribe(scoreProcessor) // 'Scores' DynamoDB table streams NEW_AND_OLD_IMAGES change events to scoreProcessor Lambda

        // getParameter permissions for hue-remote-username & hue-access-token
        scoreProcessor.link(
            Link(
                "hue-remote-username-token-permissions-link",
                effect: "Allow",
                actions: ["ssm:GetParameter"],
                resources: [
                    ssmParameterARN("hue-remote-username"),
                    ssmParameterARN("hue-access-token")
                ],
                properties: nil
            )
        )


        // MARK: Hue API Token Refresher Infrastructure
        let hueTokenRefresherCron = AWS.Cron(
            "hue-token-refresher-cron-job",
            schedule: .rate(.days(3))
        )

        let hueTokenRefresherFunction = AWS.Function(
            "hue-token-refresher",
            targetName: "HueTokenRefresher",
			build: .staticLinuxSDK,
			buildOptions: .stripSymbols
        )

        hueTokenRefresherCron.invoke(hueTokenRefresherFunction) // cron job triggers the hue token refresher

        // get and update hue access tokens
        hueTokenRefresherFunction.link(
            Link(
                "hue-tokens-permissions-link",
                effect: "Allow",
                actions: ["ssm:GetParameter", "ssm:PutParameter"],
                resources: [
                    ssmParameterARN("hue-client-id"),
                    ssmParameterARN("hue-client-secret"),
                    ssmParameterARN("hue-access-token"),
                    ssmParameterARN("hue-refresh-token")
                ],
                properties: nil
            )
        )

        addMonitoring(
            scheduler: sportsApiScheduler,
            poller: sportsApiPoller,
            pollerQueue: sportsApiPollerQueue,
            scoreProcessor: scoreProcessor,
            tokenRefresher: hueTokenRefresherFunction
        )

        return Outputs([
            "poller-cron-job-name": pollerCron.name,
            "sports-api-scheduler-function-name": sportsApiScheduler.name,
            "sports-api-poller-queue-name": sportsApiPollerQueue.name,
            "sports-api-poller-queue-url": sportsApiPollerQueue.url,
            "sports-poller-function-name": sportsApiPoller.name,
            "scores-table-name": scoresTable.name,
            "score-processor-function-name": scoreProcessor.name,
            "hue-token-refresher-cron-job-name": hueTokenRefresherCron.name,
            "hue-token-refresher-function-name": hueTokenRefresherFunction.name
        ])
    }
}
