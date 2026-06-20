//
//  AppRuntime.swift
//  CodeEdit
//
//  Created by Claude on 01/05/2026.
//

import Foundation

enum AppRuntime {
    static var applicationName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "CodeEdit"
    }

    static var applicationSupportURL: URL {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: applicationName, directoryHint: .isDirectory)
    }

    static var sharedDefaultsSuiteName: String {
        "\(Bundle.main.bundleIdentifier ?? "app.codeedit.CodeEdit").shared"
    }

    static var keychainPrefix: String {
        "\(applicationName)_"
    }

    static var isCodeEditV2Fork: Bool {
        applicationName == "CodeEditV2" || Bundle.main.bundleIdentifier == "app.codeedit.CodeEditV2"
    }
}
