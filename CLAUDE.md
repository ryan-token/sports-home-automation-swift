# Sports Home Automation - Agent Guide

## Overview

This is a Swift on Server project that uses [Swift Cloud](https://github.com/swift-cloud/swift-cloud) for infrastructure-as-code on AWS. It polls sports APIs for live scores and controls Philips Hue smart lights when favorite teams score or win.

**Runtime:** AWS Lambda (Swift, cross-compiled for Linux via Static Linux SDK)
**IaC:** Swift Cloud (wraps Pulumi)
**AWS SDK:** [Soto](https://github.com/soto-project/soto) v7+ (NOT the official AWS SDK for Swift)
**Swift version:** 6.2+ with strict concurrency

## Project Structure

```
Sources/
  Infra/Project.swift          # AWS infrastructure definition (Swift Cloud)
  Scheduler/main.swift          # Lambda: sends 6 staggered SQS messages per minute
  Poller/main.swift             # Lambda: polls sports APIs, writes to DynamoDB
  ScoreProcessor/main.swift     # Lambda: processes DynamoDB streams, controls Hue lights
  HueTokenRefresher/main.swift  # Lambda: refreshes Hue OAuth tokens every 3 days
  Models/                       # Shared data models (GameItem, GameInfo, API responses - only the fields the Poller reads)
  Models/Teams.swift            # The teams to follow, their sports, and their light colors (edit here to change teams)
  SSMUtils/SSM.swift            # Shared SSM Parameter Store helpers
  SharedUtils/SharedUtils.swift # Season detection logic (isFootballSeason, isBasketballSeason)
  Extensions/Date+Month-Day.swift # Date helper extensions
Package.swift                   # SPM manifest with all targets and dependencies
```

## Architecture

### Event pipeline

```
EventBridge (1 min) → Scheduler → SQS (6 messages, 10s delays) → Poller → DynamoDB → ScoreProcessor → Hue API
```

1. **Scheduler** - Triggered by EventBridge every minute. Sends 6 SQS messages with 0/10/20/30/40/50 second delays to simulate 10-second polling.
2. **Poller** - Triggered by SQS. Checks the NCAA API (cfb, mbb, wbb) and ESPN API (nfl) via `HTTPClient.shared` for every team in `MonitoredTeam.all` that follows that sport. Writes game state to DynamoDB.
3. **ScoreProcessor** - Triggered by DynamoDB Streams (NEW_AND_OLD_IMAGES). Compares old/new images to detect scoring events and game endings. Flashes the Hue "Game Day" zone in team colors on score/win via the CLIP v2 remote API (one `grouped_light` PUT per color change, scheduled on a fixed clock), then restores each light to its pre-flash state. See `hue-api-guide.md`.
4. **HueTokenRefresher** - Separate cron (every 3 days). Refreshes Hue OAuth tokens stored in SSM Parameter Store.

### Key dependencies

| Package | Product | Used by | Purpose |
|---------|---------|---------|---------|
| soto | SotoSQS | Scheduler | Send delayed SQS messages |
| soto | SotoDynamoDB | Poller | Write game state |
| soto | SotoSSM | SSMUtils, ScoreProcessor, HueTokenRefresher | Read/write Hue API tokens |
| swift-cloud | Cloud | Infra | Infrastructure definition |
| swift-cloud | CloudSDK | Scheduler, Poller | Runtime helpers (`Cloud.env()`) |
| swift-aws-lambda-runtime | AWSLambdaRuntime | All Lambdas | Lambda handler runtime |
| swift-aws-lambda-events | AWSLambdaEvents | All Lambdas | Event type definitions |
| async-http-client | AsyncHTTPClient | Poller, ScoreProcessor, HueTokenRefresher | HTTP requests to external APIs |

### Soto client lifecycle

Each Lambda executable creates an `AWSClient` and service client at the module level (before the `LambdaRuntime` closure). This ensures the client is created once on cold start and reused across invocations. `client.shutdown()` is called after `runtime.run()` exits.

```swift
let awsClient = AWSClient()
let ssm = SSM(client: awsClient, region: .useast1)

let runtime = LambdaRuntime { (event, context) async throws -> Bool in
    // use ssm here
}

try await runtime.run()
try await awsClient.shutdown()
```

SSMUtils functions accept an `SSM` client parameter so callers control the lifecycle.

## Deployment

### Build configuration

- All Lambda functions use `build: .staticLinuxSDK` in `Project.swift` (no Docker required)
- Default `packageType: .zip` deploys binaries as zip archives directly to Lambda
- All Lambda functions use `buildOptions: .stripSymbols` in `Project.swift` to keep zips under the 70MB Lambda limit
- Do NOT set `packageType: .image` unless Docker is available - it forces container-based deployment

### Toolchain requirements

Deployment requires the **swift.org open-source toolchain** (installed via [Swiftly](https://swiftly.dev/)), NOT the Xcode-bundled Apple toolchain. The Static Linux SDK is only compatible with the swift.org build. The SDK version must exactly match the toolchain version.

### Deploy command

```bash
swift run Infra deploy --stage prod
```

## Important conventions

- **No official AWS SDK.** This project uses Soto instead of `aws-sdk-swift` because `aws-crt-swift` (a C dependency of the official SDK) cannot cross-compile with the Static Linux SDK.
- **Region is always `us-east-1`.** All AWS resources and Soto clients use `.useast1`.
- **SSM parameters** store Hue API credentials: `hue-client-id`, `hue-client-secret`, `hue-access-token`, `hue-refresh-token`, `hue-remote-username`. These are sensitive - never hardcode or log them.
- **Teams are configured in `Sources/Models/Teams.swift`.** `MonitoredTeam.all` lists each team's API name, sports, and light colors; the Poller and ScoreProcessor both read it. Team names are matched exactly against `names.short` (NCAA) or `team.name` (ESPN), never by substring (the FBS scoreboard has both "Missouri" and "Missouri St.").
- **Hue lights are configured in the Hue app, not in code.** ScoreProcessor looks up the "Game Day" zone by name at runtime; add or remove lights there.
- **Season guards.** The Scheduler and Poller exit early if it's not football or basketball season (defined in `SharedUtils.swift`).
- **External API requests must send a `User-Agent`.** ESPN's CDN returns `403 Forbidden` for requests without a recognized HTTP-library User-Agent (AsyncHTTPClient sends none by default). The Poller sends `AsyncHTTPClient`; unknown or spoofed-browser UAs are also blocked.
- **Decode only what you read.** API response models include just the fields the code consumes so unused upstream sections (e.g. ESPN's `leagues`/`calendar`) can't break decoding.
- **Strict concurrency.** Swift 6 language mode (tools-version 6.2) enables strict concurrency for all targets.
- **No Combine.** Use async/await throughout. No `DispatchQueue` either.
