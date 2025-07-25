//
//  SubscriptionManager.swift
//  Unwatched
//

import Foundation
import SwiftData
import OSLog
import UnwatchedShared

@ModelActor
actor SubscriptionActor {
    var imageUrlsToBeDeleted = [URL]()

    func getActiveSubscriptions(
        _ searchText: String,
        _ sort: [SortDescriptor<Subscription>]
    ) -> [SendableSubscription] {
        let fetch = FetchDescriptor<Subscription>(
            predicate: #Predicate {
                $0.isArchived == false && (searchText.isEmpty || $0.title.localizedStandardContains(searchText))
            },
            sortBy: sort
        )
        let subs = try? modelContext.fetch(fetch)
        return subs?.compactMap { $0.toExport } ?? []
    }

    func unarchive(_ sub: Subscription) {
        sub.isArchived = false
        sub.subscribedDate = .now
    }

    func subscribeTo(_ info: SubscriptionInfo?, _ subsciptionId: PersistentIdentifier?) async throws {
        // check if it already exists, if it does, subscribe
        if let id = subsciptionId, let sub = self[id, as: Subscription.self] {
            unarchive(sub)
            Log.info("successfully subscribed via subId")
            try modelContext.save()
            return
        }

        var fetch: FetchDescriptor<Subscription>
        if let playlistId = info?.playlistId {
            print("playlistId", playlistId)
            fetch = FetchDescriptor<Subscription>(predicate: #Predicate {
                $0.youtubePlaylistId == playlistId
            })
        } else if let channelId = info?.channelId {
            fetch = FetchDescriptor<Subscription>(predicate: #Predicate {
                $0.youtubePlaylistId == nil && $0.youtubeChannelId == channelId
            })
        } else {
            throw SubscriptionError.noInfoFoundToSubscribeTo
        }

        fetch.fetchLimit = 1
        let subs = try? modelContext.fetch(fetch)
        if let first = subs?.first {
            unarchive(first)
            try modelContext.save()
            return
        }
        guard let subscriptionInfo = info else {
            Log.info("no channel info here")
            return
        }
        // if it doesn't exist get url and run the regular subscription flow
        if subscriptionInfo.rssFeed == nil {
            throw SubscriptionError.notSupported
        }

        let subStates = try await addSubscriptions(subscriptionInfo: [subscriptionInfo])
        if let first = subStates.first {
            if !(first.success || first.alreadyAdded) {
                throw SubscriptionError.couldNotSubscribe(first.error ?? "unknown")
            }
        }
        try modelContext.save()
    }

    func addSubscriptions(
        subscriptionInfo: [SubscriptionInfo] = [],
        sendableSubs: [SendableSubscription] = []
    ) async throws -> [SubscriptionState] {
        var subscriptionStates = [SubscriptionState]()
        Log.info("addSubscriptions: \(subscriptionStates)")
        try await withThrowingTaskGroup(of: (SubscriptionState, SendableSubscription?).self) { group in
            if !subscriptionInfo.isEmpty {
                for info in subscriptionInfo {
                    if let url = info.rssFeedUrl ?? info.url {
                        group.addTask {
                            var (subState, sendableSub) = await self.loadSubscriptionInfo(
                                from: url,
                                unarchiveSubIfAvailable: true
                            )
                            if let sub = sendableSub {
                                sendableSub = SubscriptionActor.mergeSubscriptionInfoAndSendableSub(info, sub)
                            }
                            return (subState, sendableSub)
                        }
                    } else {
                        Log.warning("channel info has no url")
                        throw SubscriptionError.noInfoFoundToSubscribeTo
                    }
                }
            } else if !sendableSubs.isEmpty {
                for sub in sendableSubs {
                    group.addTask {
                        return await self.verifySubscriptionInfo(sub, unarchiveSubIfAvailable: true)
                    }
                }
            }

            for try await (subState, sendableSub) in group {
                subscriptionStates.append(subState)
                if let sendableSub = sendableSub {
                    let sub = sendableSub.createSubscription()
                    modelContext.insert(sub)
                }
            }
        }
        try modelContext.save()
        return subscriptionStates
    }

    private static func mergeSubscriptionInfoAndSendableSub(
        _ info: SubscriptionInfo,
        _ sendableSub: SendableSubscription) -> SendableSubscription {
        var sub = sendableSub
        sub.link = sub.link ?? info.rssFeedUrl
        sub.youtubeChannelId = sub.youtubeChannelId ?? info.channelId
        sub.youtubeUserName = sub.youtubeUserName ?? info.userName
        sub.thumbnailUrl = sub.thumbnailUrl ?? info.imageUrl
        return sub
    }

    static func getSubscription(url: URL,
                                channelId: String? = nil,
                                userName: String? = nil,
                                playlistId: String? = nil) async throws -> SendableSubscription? {
        let feedUrl = try await SubscriptionActor.getChannelFeedFromUrl(url: url,
                                                                        channelId: channelId,
                                                                        userName: userName,
                                                                        playlistId: playlistId)
        Log.info("getSubscription, feed: \(feedUrl.absoluteString)")
        var sendableSub = try await VideoCrawler.loadSubscriptionFromRSS(feedUrl: feedUrl)
        sendableSub.youtubeUserName = sendableSub.youtubeUserName ?? userName
        return sendableSub
    }

    static func getChannelFeedFromUrl(
        url: URL,
        channelId: String?,
        userName: String?,
        playlistId: String?
    ) async throws -> URL {
        Log.info("getChannelFeedFromUrl: \(url.absoluteString)")
        if UrlService.isYoutubeFeedUrl(url: url) {
            return url
        }
        if let playlistId, let feedUrl = try? UrlService.getPlaylistFeedUrl(playlistId) {
            return feedUrl
        }
        if let channelId {
            return try UrlService.getFeedUrlFromChannelId(channelId)
        }
        guard let userName else {
            throw SubscriptionError.failedGettingChannelIdFromUsername("Username was empty")
        }
        let loadedChannelId = try await YoutubeDataAPI.getYtChannelId(from: userName)
        return try UrlService.getFeedUrlFromChannelId(loadedChannelId)
    }

    func getAllFeedUrls() throws -> [(title: String, link: URL?)] {
        let predicate = #Predicate<Subscription> { $0.isArchived == false }
        let fetchDescriptor = FetchDescriptor<Subscription>(predicate: predicate)
        let subs = try modelContext.fetch(fetchDescriptor)
        return subs.map { (title: $0.title, link: $0.link) }
    }

    func unsubscribe(_ channelId: String?, playlistId: String?) throws {
        if channelId == nil && playlistId == nil {
            throw SubscriptionError.noInfoFoundToUnsubscribe
        }
        let fetch = FetchDescriptor<Subscription>(predicate: #Predicate {
            (channelId != nil && $0.youtubeChannelId == channelId)
                || (playlistId != nil && $0.youtubePlaylistId == playlistId)
        })
        let subs = try modelContext.fetch(fetch)
        try deleteSubscriptions(subs)
    }

    func deleteSubscriptions(_ subscriptionIds: [PersistentIdentifier]) throws {
        let subs = subscriptionIds.compactMap { self[$0, as: Subscription.self] }
        try deleteSubscriptions(subs)
        try modelContext.save()
    }

    func cleanupArchivedSubscriptions() throws {
        let fetch = FetchDescriptor<Subscription>(predicate: #Predicate {
            $0.isArchived == true
        })
        guard let subs = try? modelContext.fetch(fetch) else {
            Log.info("cleanupArchivedSubscriptions: no subscriptions found")
            return
        }
        try deleteSubscriptions(subs)
        try modelContext.save()
    }

    private func deleteSubscriptions(_ subscriptions: [Subscription]) throws {
        for subscription in subscriptions {
            var hasVideosLeft = false
            for video in subscription.videos ?? [] {
                if video.queueEntry == nil &&
                    video.watchedDate == nil &&
                    video.bookmarkedDate == nil {
                    CleanupService.deleteVideo(video, modelContext)
                } else {
                    hasVideosLeft = true
                }
            }
            if hasVideosLeft {
                subscription.mostRecentVideoDate = nil
                subscription.isArchived = true
            } else {
                modelContext.delete(subscription)
            }
        }
    }
}
