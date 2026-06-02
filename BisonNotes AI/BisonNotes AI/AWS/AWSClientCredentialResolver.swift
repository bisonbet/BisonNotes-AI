//
//  AWSClientCredentialResolver.swift
//  BisonNotes AI
//

import AWSSDKIdentity
import SmithyIdentity

enum AWSClientCredentialResolver {
    static func staticResolver(
        accessKeyId: String,
        secretAccessKey: String,
        sessionToken: String? = nil
    ) -> StaticAWSCredentialIdentityResolver {
        StaticAWSCredentialIdentityResolver(
            AWSCredentialIdentity(
                accessKey: accessKeyId,
                secret: secretAccessKey,
                sessionToken: sessionToken
            )
        )
    }

    static func staticResolver(credentials: AWSCredentials) -> StaticAWSCredentialIdentityResolver {
        staticResolver(
            accessKeyId: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey
        )
    }
}
