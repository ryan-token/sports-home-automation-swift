//
//  Monitoring.swift
//  sports-home-automation-swift
//

import Cloud

/// The field of Pulumi's `aws:ssm:getParameter` result that this file reads.
struct SSMParameter {
    let value: String
}

/// Email alarms and a CloudWatch dashboard (CloudWatch > Dashboards > sports-home-automation).
///
/// The handlers catch their failures and log them rather than throwing, so Lambda's own Errors
/// metric stays at zero when the scores API or the Hue bridge is down. The real signal is the log
/// level: metric filters count `error` and `warning` lines per function, and the alarms watch those.
func addMonitoring(
    scheduler: AWS.Function,
    poller: AWS.Function,
    pollerQueue: AWS.Queue,
    scoreProcessor: AWS.Function,
    tokenRefresher: AWS.Function
) {
    let context: Context = Context.current
    let namespace = "SportsHomeAutomation"
    let functions = [scheduler, poller, scoreProcessor, tokenRefresher]

    // Read from SSM at deploy time so this public repo never contains the address.
    let alertEmail = Variable<SSMParameter>.invoke(
        name: "alert-email",
        function: "aws:ssm:getParameter",
        arguments: ["name": "/sports-home-automation/alert-email"]
    ).output.value

    let topic = Resource(
        name: "alerts-topic",
        type: "aws:sns:Topic",
        properties: ["name": "sports-home-automation-alerts"],
        options: nil,
        context: context
    )
    let topicArn: Output<String> = topic.output.keyPath("arn")

    // AWS emails a confirmation link on the first deploy; alarms are only delivered once it's clicked.
    _ = Resource(
        name: "alerts-email",
        type: "aws:sns:TopicSubscription",
        properties: ["topic": topicArn, "protocol": "email", "endpoint": alertEmail],
        options: nil,
        context: context
    )

    // MARK: Log-level metrics

    func countLines(_ name: String, level: String, in function: AWS.Function) {
        _ = Resource(
            name: "\(name)-metric-filter",
            type: "aws:cloudwatch:LogMetricFilter",
            properties: [
                "name": name,
                "logGroupName": "/aws/lambda/\(function.name)",
                // swift-aws-lambda-runtime writes "<timestamp> <level> LambdaRuntime: ...".
                "pattern": "\"\(level) LambdaRuntime:\"",
                "metricTransformation": [
                    "name": name,
                    "namespace": namespace,
                    "value": "1",
                    "defaultValue": "0",
                ],
            ],
            options: nil,
            context: context
        )
    }

    countLines("SchedulerErrors", level: "error", in: scheduler)
    countLines("ScoresFeedErrors", level: "error", in: poller)
    countLines("HueErrors", level: "error", in: scoreProcessor)
    countLines("HueWarnings", level: "warning", in: scoreProcessor)
    countLines("TokenRefreshErrors", level: "error", in: tokenRefresher)

    // MARK: Alarms

    func alarm(
        _ name: String,
        description: String,
        threshold: Int,
        comparison: String = "GreaterThanOrEqualToThreshold",
        missingData: String = "notBreaching",
        metrics: [AnyEncodable]
    ) -> Output<String> {
        let resource = Resource(
            name: "\(name)-alarm",
            type: "aws:cloudwatch:MetricAlarm",
            properties: [
                "name": "sports-\(name)",
                "alarmDescription": description,
                "comparisonOperator": comparison,
                "threshold": threshold,
                "evaluationPeriods": 1,
                "treatMissingData": missingData,
                "metricQueries": AnyEncodable(metrics),
                "alarmActions": [topicArn],
                "okActions": [topicArn],
            ],
            options: nil,
            context: context
        )
        return resource.output.keyPath("arn")
    }

    func metric(
        _ id: String,
        _ metricName: String,
        namespace: String,
        dimensions: [String: Output<String>] = [:],
        period: Int,
        stat: String = "Sum",
        returnData: Bool = false
    ) -> AnyEncodable {
        [
            "id": id,
            "returnData": returnData,
            "metric": [
                "metricName": metricName,
                "namespace": namespace,
                "period": period,
                "stat": stat,
                "dimensions": AnyEncodable(dimensions),
            ],
        ]
    }

    func expression(_ expression: String, label: String) -> AnyEncodable {
        ["id": "result", "expression": expression, "label": label, "returnData": true]
    }

    // The cron invokes the scheduler every minute all year (out of season it returns before queueing
    // any polls, so the poller's own invocations can't be watched), so 10 quiet minutes means the
    // schedule has stopped and no score will flash the lights.
    let stalled = alarm(
        "pipeline-stalled",
        description: "The scheduler hasn't run in 10 minutes, so scores aren't being checked. Check the EventBridge schedule and the scheduler log group.",
        threshold: 1,
        comparison: "LessThanThreshold",
        missingData: "breaching",
        metrics: [
            metric("runs", "Invocations", namespace: "AWS/Lambda", dimensions: ["FunctionName": scheduler.name], period: 600),
            expression("FILL(runs, 0)", label: "Scheduler runs"),
        ]
    )

    // The NCAA API returns the odd 502, which is harmless at 6 polls a minute. 20 failures in 15
    // minutes means it has been down for a while.
    let scoresFeed = alarm(
        "scores-feed-failing",
        description: "The poller logged 20 or more errors in 15 minutes: the NCAA scores API is down or DynamoDB writes are failing, so scores may be missed. Check the poller log group.",
        threshold: 20,
        metrics: [
            metric("errors", "ScoresFeedErrors", namespace: namespace, period: 900),
            expression("FILL(errors, 0)", label: "Poller errors"),
        ]
    )

    // A 207 (some lights unreachable) is only a warning; an error means the flash didn't happen.
    let lights = alarm(
        "lights-failed",
        description: "The score processor couldn't flash the lights: the Hue API rejected a request or the zone is missing. Check the score processor log group.",
        threshold: 1,
        metrics: [
            metric("errors", "HueErrors", namespace: namespace, period: 300),
            expression("FILL(errors, 0)", label: "Hue errors"),
        ]
    )

    // The access token expires a few days after a missed refresh, after which every flash fails.
    let tokenRefresh = alarm(
        "hue-token-refresh-failed",
        description: "Refreshing the Hue tokens failed, so the lights will stop responding once the access token expires. Check the hue-token-refresher log group; a 401 means the refresh token needs re-authorizing.",
        threshold: 1,
        metrics: [
            metric("logged", "TokenRefreshErrors", namespace: namespace, period: 3600),
            metric("crashed", "Errors", namespace: "AWS/Lambda", dimensions: ["FunctionName": tokenRefresher.name], period: 3600),
            expression("FILL(logged, 0) + FILL(crashed, 0)", label: "Refresh failures"),
        ]
    )

    // Crashes and timeouts, which the log-level alarms above can't see, plus the scheduler failing to
    // queue polls.
    var crashMetrics: [AnyEncodable] = [metric("queueing", "SchedulerErrors", namespace: namespace, period: 300)]
    for (index, function) in functions.enumerated() {
        crashMetrics.append(metric("f\(index)", "Errors", namespace: "AWS/Lambda", dimensions: ["FunctionName": function.name], period: 300))
    }
    crashMetrics.append(expression((["queueing"] + functions.indices.map { "f\($0)" }).map { "FILL(\($0), 0)" }.joined(separator: " + "), label: "Crashes, timeouts and failed queueing"))
    let crashes = alarm(
        "function-crashes",
        description: "A function crashed or timed out, or the scheduler couldn't queue polls, in the last 5 minutes. Check the /aws/lambda/prod-* log groups.",
        threshold: 1,
        metrics: crashMetrics
    )

    // Polls that failed every retry land here instead of disappearing.
    let deadLetters = alarm(
        "dead-letters",
        description: "Poll messages are piling up in the dead-letter queue because the poller failed them repeatedly. Check the poller log group, then purge the DLQ.",
        threshold: 1,
        metrics: [
            metric("waiting", "ApproximateNumberOfMessagesVisible", namespace: "AWS/SQS", dimensions: ["QueueName": pollerQueue.deadLetterQueue.name], period: 300, stat: "Maximum"),
            expression("FILL(waiting, 0)", label: "Dead letters"),
        ]
    )

    // MARK: Dashboard

    let lambda = { (metricName: String, function: AWS.Function, options: String) in
        #"["AWS/Lambda", "\#(metricName)", "FunctionName", "\#(function.name)", \#(options)]"#
    }
    let custom = { (metricName: String, options: String) in
        #"["\#(namespace)", "\#(metricName)", \#(options)]"#
    }
    let red = ##""color": "#d62728""##
    let orange = ##""color": "#ff7f0e""##

    let body = #"""
    {
      "start": "-PT24H",
      "widgets": [
        {
          "type": "text", "x": 0, "y": 0, "width": 24, "height": 2,
          "properties": {
            "markdown": "## Sports home automation\nEvery 10 seconds the poller checks the NCAA scores API and saves Tulsa games to DynamoDB. A new score or a win triggers the score processor, which flashes the Hue lights. The token refresher renews the Hue tokens every 3 days. The alarms below email you when they trip."
          }
        },
        {
          "type": "alarm", "x": 0, "y": 2, "width": 24, "height": 3,
          "properties": {
            "title": "Alarms",
            "alarms": ["\#(stalled)", "\#(scoresFeed)", "\#(lights)", "\#(tokenRefresh)", "\#(crashes)", "\#(deadLetters)"]
          }
        },
        {
          "type": "metric", "x": 0, "y": 5, "width": 12, "height": 6,
          "properties": {
            "title": "Score checks vs scores API failures (per 5 minutes; ~30 in season, none out of it)",
            "region": "us-east-1", "view": "timeSeries", "stat": "Sum", "period": 300,
            "metrics": [
              \#(lambda("Invocations", poller, #"{ "label": "Score checks" }"#)),
              \#(custom("ScoresFeedErrors", #"{ "label": "Failed API calls", \#(red) }"#))
            ]
          }
        },
        {
          "type": "metric", "x": 12, "y": 5, "width": 12, "height": 6,
          "properties": {
            "title": "Lights: score events and Hue results",
            "region": "us-east-1", "view": "timeSeries", "stat": "Sum", "period": 300,
            "metrics": [
              \#(lambda("Invocations", scoreProcessor, #"{ "label": "Score changes processed" }"#)),
              \#(custom("HueWarnings", #"{ "label": "Some lights unreachable", \#(orange) }"#)),
              \#(custom("HueErrors", #"{ "label": "Flash failed", \#(red) }"#))
            ]
          }
        },
        {
          "type": "metric", "x": 0, "y": 11, "width": 8, "height": 6,
          "properties": {
            "title": "Hue token refreshes (last 14 days, 1 every 3 days)",
            "region": "us-east-1", "view": "timeSeries", "stat": "Sum", "period": 86400, "start": "-P14D",
            "metrics": [
              \#(lambda("Invocations", tokenRefresher, #"{ "label": "Refreshes" }"#)),
              \#(custom("TokenRefreshErrors", #"{ "label": "Failed", \#(red) }"#))
            ]
          }
        },
        {
          "type": "metric", "x": 8, "y": 11, "width": 8, "height": 6,
          "properties": {
            "title": "Queue: poll backlog and dead letters",
            "region": "us-east-1", "view": "timeSeries", "period": 300,
            "metrics": [
              ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", "\#(pollerQueue.name)", { "stat": "Maximum", "label": "Oldest waiting poll (seconds)" }],
              ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", "\#(pollerQueue.deadLetterQueue.name)", { "stat": "Maximum", "label": "Dead letters", \#(red), "yAxis": "right" }]
            ]
          }
        },
        {
          "type": "metric", "x": 16, "y": 11, "width": 8, "height": 6,
          "properties": {
            "title": "Crashes and timeouts by function",
            "region": "us-east-1", "view": "timeSeries", "stacked": true, "stat": "Sum", "period": 300,
            "metrics": [
              \#(lambda("Errors", scheduler, #"{ "label": "Scheduler" }"#)),
              \#(lambda("Errors", poller, #"{ "label": "Poller" }"#)),
              \#(lambda("Errors", scoreProcessor, #"{ "label": "Score processor" }"#)),
              \#(lambda("Errors", tokenRefresher, #"{ "label": "Token refresher" }"#))
            ]
          }
        }
      ]
    }
    """#

    _ = Resource(
        name: "dashboard",
        type: "aws:cloudwatch:Dashboard",
        properties: ["dashboardName": "sports-home-automation", "dashboardBody": AnyEncodable(stringLiteral: body)],
        options: nil,
        context: context
    )
}
