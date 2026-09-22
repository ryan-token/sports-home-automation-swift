//
//  SSM.swift
//  sports-home-automation-swift
//
//  Created by Ryan Token on 2/5/25.
//

import AWSLambdaRuntime
import Models
import SotoSSM

public func getSSMParameterValue(parameterName: String, ssm: SSM, context: LambdaContext) async throws -> String? {
    do {
        let response = try await ssm.getParameter(.init(name: parameterName))
        guard let parameterValue = response.parameter?.value else {
            context.logger.error("Parameter value for \(parameterName) is nil")
            return nil
        }

        context.logger.info("Retrieved parameter \(parameterName)")
        return parameterValue
    } catch {
        context.logger.error("Error fetching parameter \(parameterName): \(error)")
        return nil
    }
}

public func updateSSMParameters(tokenResponse: HueTokenResponse, ssm: SSM) async throws {
    _ = try await ssm.putParameter(.init(
        name: "hue-access-token",
        overwrite: true,
        type: .string,
        value: tokenResponse.access_token
    ))

    _ = try await ssm.putParameter(.init(
        name: "hue-refresh-token",
        overwrite: true,
        type: .string,
        value: tokenResponse.refresh_token
    ))
}
