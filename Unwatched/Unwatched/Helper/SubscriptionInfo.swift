//
//  SubscriptionInfo.swift
//  Unwatched
//

import Foundation

struct SubscriptionInfo {
    var url: URL?
    var channelId: String?
    var description: String?
    var rssFeed: String?
    var title: String?
    var userName: String?
    var playlistId: String?
    var imageUrl: URL?

    var rssFeedUrl: URL? {
        get {
            if _rssFeedUrl != nil {
                return _rssFeedUrl
            }
            if let playlistId,
               let url = try? UrlService.getPlaylistFeedUrl(playlistId) {
                return url
            }
            if let channelId {
                return try? UrlService.getFeedUrlFromChannelId(channelId)
            }
            return nil
        }
        set {
            _rssFeedUrl = newValue
        }
    }

    private var _rssFeedUrl: URL?

    init(
        _ url: URL?,
        _ channelId: String? = nil,
        _ description: String? = nil,
        _ rssFeed: String? = nil,
        _ title: String? = nil,
        _ userName: String? = nil,
        _ playlistId: String? = nil,
        _ imageUrl: String? = nil
    ) {
        self.url = url
        self.channelId = channelId
        self.description = description
        self.rssFeed = rssFeed
        self.title = title
        self.userName = userName
        self.playlistId = playlistId
        if let imageUrl = imageUrl {
            self.imageUrl = URL(string: imageUrl)
        }
    }

    init(channelId: String? = nil, userName: String? = nil, playlistId: String? = nil) {
        self.channelId = channelId
        self.userName = userName
        self.playlistId = playlistId
    }

    init(rssFeedUrl: URL?) {
        self.rssFeedUrl = rssFeedUrl
    }
}
