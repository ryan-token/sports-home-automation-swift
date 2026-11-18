// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "sports-home-automation-swift",
	platforms: [.macOS(.v26)],
    products: [
        .library(name: "Models", targets: ["Models"]),
        .library(name: "Extensions", targets: ["Extensions"]),
        .library(name: "SharedUtils", targets: ["SharedUtils"]),
        .library(name: "SSMUtils", targets: ["SSMUtils"])
    ],
    dependencies: [
        .package(url: "https://github.com/swift-cloud/swift-cloud.git", branch: "main"),
        .package(url: "https://github.com/swift-server/swift-aws-lambda-runtime.git", branch: "main"),
        .package(url: "https://github.com/swift-server/swift-aws-lambda-events", branch: "main"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.0.0"),
        .package(url: "https://github.com/soto-project/soto.git", from: "7.0.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "Models",
            dependencies: []
        ),
        .target(
            name: "Extensions",
            dependencies: []
        ),
        .target(
            name: "SharedUtils",
            dependencies: ["Extensions"]
        ),
        .target(
            name: "SSMUtils",
            dependencies: [
                "Models",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "SotoSSM", package: "soto")
            ]
        ),
        .executableTarget(
            name: "Infra",
            dependencies: [
                .product(name: "Cloud", package: "swift-cloud")
            ]
        ),
        .executableTarget(
            name: "Scheduler",
            dependencies: [
                "SharedUtils",
                .product(name: "CloudSDK", package: "swift-cloud"),
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "SotoSQS", package: "soto")
            ]
        ),
        .executableTarget(
            name: "Poller",
            dependencies: [
                "Models",
                "SharedUtils",
                .product(name: "CloudSDK", package: "swift-cloud"),
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "SotoDynamoDB", package: "soto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .executableTarget(
            name: "ScoreProcessor",
            dependencies: [
                "Models",
                "SharedUtils",
                "SSMUtils",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "SotoSSM", package: "soto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .executableTarget(
            name: "HueTokenRefresher",
            dependencies: [
                "SharedUtils",
                "SSMUtils",
                .product(name: "AWSLambdaRuntime", package: "swift-aws-lambda-runtime"),
                .product(name: "AWSLambdaEvents", package: "swift-aws-lambda-events"),
                .product(name: "SotoSSM", package: "soto"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        )
    ]
)
