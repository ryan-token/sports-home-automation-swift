# Sports Home Automation with Swift Cloud

Backend serverless IaC on AWS to remotely control my Philips Hue bulbs whenever my favorite sports teams score or win. Written in Swift and deployed via [Swift Cloud](https://github.com/swift-cloud/swift-cloud).

Read the blog post about it [here](https://www.ryantoken.com/blog/serverless-swift).

## Infrastructure

All infrastructure is defined in `Sources/Infra/Project.swift` and deployed to AWS.

**Core pipeline** (polls sports scores every 10 seconds):
1. **EventBridge Cron** - triggers the scheduler Lambda every minute
2. **Scheduler Lambda** - sends 6 SQS messages with staggered 10-second delays
3. **SQS Queue** - holds the polling trigger messages
4. **Poller Lambda** - triggered by SQS, polls the [ncaa-api](https://github.com/henrygd/ncaa-api) for college football/basketball scores and the [public-espn-api](https://github.com/pseudo-r/Public-ESPN-API) for NFL scores for the teams in `Sources/Models/Teams.swift`, writes results to DynamoDB
5. **DynamoDB Table** - stores current game state with streaming enabled (new + old images)
6. **ScoreProcessor Lambda** - triggered by DynamoDB Streams, detects scoring events and wins, then flashes Philips Hue lights in the appropriate team colors and puts them back how they were

**Hue token refresh** (keeps API tokens valid):
1. **EventBridge Cron** - triggers the token refresher every 3 days
2. **HueTokenRefresher Lambda** - refreshes Hue OAuth tokens stored in SSM Parameter Store

## Deployment

### Prerequisites

This project deploys without Docker using the [Swift Static Linux SDK](https://www.swift.org/install/macos/#swift-sdk-bundles) for cross-compilation from macOS to Linux.

**1. Install Swiftly (Swift toolchain manager)**

The Static Linux SDK requires the open-source Swift toolchain from swift.org, not the one bundled with Xcode. [Swiftly](https://www.swift.org/install/macos/) manages this:

```bash
curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && \
installer -pkg swiftly.pkg -target CurrentUserHomeDirectory && \
~/.swiftly/bin/swiftly init --quiet-shell-followup && \
. "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}/env.sh" && \
hash -r
```

Then install the matching Swift version:

```bash
swiftly install 6.3
```

> **Important:** The Swiftly-managed toolchain is only used in the terminal for deployments. Xcode continues using its own bundled toolchain for iOS/macOS development - they don't interfere with each other.

**2. Install the Static Linux SDK**

The SDK version must match your Swift toolchain version exactly. Install from the [Swift SDK bundles page](https://www.swift.org/install/macos/#swift-sdk-bundles):

```bash
swift sdk install <url-to-matching-static-linux-sdk>
```

Verify both match:

```bash
swift --version    # should show swift.org build, NOT "Apple Swift version"
swift sdk list     # should show the matching SDK version
```

**3. AWS credentials**

Ensure your AWS credentials are configured (e.g. via `~/.aws/credentials` or environment variables).

### Commands

| Command | Description |
|---------|-------------|
| `swift run Infra deploy --stage prod` | Deploy all infrastructure |
| `swift run Infra remove --stage prod` | Remove all infrastructure |
| `swift run Infra preview --stage prod` | Preview changes before deploying |
| `swift run Infra outputs --stage prod` | View stack outputs |
| `swift run Infra cancel --stage prod` | Cancel an in-progress operation |

### Deployment notes

- **No Docker required.** All Lambda functions use `build: .staticLinuxSDK` in `Project.swift`, which cross-compiles natively on macOS using the Static Linux SDK and deploys as zip packages.
- **Binary stripping.** Lambda executable targets have `--strip-all` linker flags (Linux-only, via `Package.swift`) to keep zip packages under the 70MB Lambda deployment limit.
- **Package type must be `.zip`** (the default). Using `.image` would require Docker to build container images. If binaries ever exceed the zip limit even after stripping, `.image` is the fallback but requires Docker.

## AWS SDK

This project uses [Soto](https://github.com/soto-project/soto) (v7+) instead of the official AWS SDK for Swift. The official SDK depends on `aws-crt-swift`, which contains C code with Apple-specific headers (`TargetConditionals.h`) that break cross-compilation with the Static Linux SDK. Soto is a pure Swift implementation that cross-compiles cleanly.

Services used:
- **SotoSQS** - Scheduler sends delayed messages to the poller queue
- **SotoDynamoDB** - Poller writes game state to the Scores table
- **SotoSSM** - ScoreProcessor and HueTokenRefresher read/write Hue API tokens in Parameter Store
