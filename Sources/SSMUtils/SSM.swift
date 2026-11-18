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
        let response = try await ssm.getParameter(.init(name: parameterName, withDecryption: true))
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

// Hue rotates the refresh token on every refresh, so the new one is saved first: if saving the access token
// then fails, the next run can still refresh, whereas losing the new refresh token would mean re-authorizing
// Hue by hand.
public func updateSSMParameters(tokenResponse: HueTokenResponse, ssm: SSM) async throws {
    _ = try await ssm.putParameter(.init(
        name: "hue-refresh-token",
        overwrite: true,
        type: .secureString,
        value: tokenResponse.refresh_token
    ))

    _ = try await ssm.putParameter(.init(
        name: "hue-access-token",
        overwrite: true,
        type: .secureString,
        value: tokenResponse.access_token
    ))
}
