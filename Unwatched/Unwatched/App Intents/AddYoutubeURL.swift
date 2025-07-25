//
//  AddYoutubeURL.swift
//  Unwatched
//

import AppIntents
import SwiftData
import UnwatchedShared

struct AddYoutubeURL: AppIntent {
    static var title: LocalizedStringResource { "addYoutubeUrl" }
    static let description = IntentDescription("addYoutubeUrlDescription")

    @Parameter(title: "youtubeVideoUrl")
    var youtubeUrl: URL

    @MainActor
    func perform() async throws -> some IntentResult {
        let task = VideoService.addForeignUrls(
            [youtubeUrl],
            in: .queue,
            markAsNew: true
        )
        try await task.value
        UserDefaults.standard.set(true, forKey: Const.shortcutHasBeenUsed)
        return .result()
    }

    static var parameterSummary: some ParameterSummary {
        Summary("addYoutubeUrl \(\.$youtubeUrl)")
    }
}
