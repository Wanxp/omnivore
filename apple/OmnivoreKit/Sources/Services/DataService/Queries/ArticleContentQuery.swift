import CoreData
import Foundation
import Models
import SwiftGraphQL

extension DataService {
  struct PendingLink {
    let itemID: String
    let retryCount: Int
  }

  public func prefetchPages(itemIDs: [String]) async {
    guard let username = currentViewer?.username else { return }

    for itemID in itemIDs {
      await prefetchPage(pendingLink: PendingLink(itemID: itemID, retryCount: 1), username: username)
    }
  }

  func prefetchPage(pendingLink: PendingLink, username: String) async {
    let content = try? await articleContent(username: username, itemID: pendingLink.itemID, useCache: false)

    if content?.contentStatus == .processing, pendingLink.retryCount < 7 {
      let retryDelayInNanoSeconds = UInt64(pendingLink.retryCount * 2 * 1_000_000_000)

      do {
        try await Task.sleep(nanoseconds: retryDelayInNanoSeconds)
        logger.debug("fetching content for \(pendingLink.itemID). retry count: \(pendingLink.retryCount)")

        await prefetchPage(
          pendingLink: PendingLink(
            itemID: pendingLink.itemID,
            retryCount: pendingLink.retryCount + 1
          ),
          username: username
        )
      } catch {
        logger.debug("prefetching task was cancelled")
      }
    }
  }

  public func fetchArticleContent(
    itemID: String,
    username: String? = nil,
    requestCount: Int = 1
  ) async throws -> ArticleContent {
    guard requestCount < 7 else {
      throw ContentFetchError.badData
    }

    guard let username = username ?? currentViewer?.username else {
      throw ContentFetchError.unauthorized
    }

    let fetchedContent = try await articleContent(username: username, itemID: itemID, useCache: true)

    switch fetchedContent.contentStatus {
    case .failed:
      throw ContentFetchError.badData
    case .processing:
      let retryDelayInNanoSeconds = UInt64(requestCount * 2 * 1_000_000_000)
      try await Task.sleep(nanoseconds: retryDelayInNanoSeconds)
      logger.debug("fetching content for \(itemID). request count: \(requestCount)")
      return try await fetchArticleContent(itemID: itemID, username: username, requestCount: requestCount + 1)
    case .succeeded, .unknown:
      return fetchedContent
    }
  }

  // swiftlint:disable:next function_body_length
  public func articleContent(
    username: String,
    itemID: String,
    useCache: Bool
  ) async throws -> ArticleContent {
    struct ArticleProps {
      let item: InternalLinkedItem
      let htmlContent: String
      let highlights: [InternalHighlight]
      let contentStatus: Enums.ArticleSavingRequestStatus?
    }

    if useCache, let cachedContent = await cachedArticleContent(itemID: itemID) {
      return cachedContent
    }

    enum QueryResult {
      case success(result: ArticleProps)
      case error(error: String)
    }

    let articleSelection = Selection.Article {
      ArticleProps(
        item: InternalLinkedItem(
          id: try $0.id(),
          title: try $0.title(),
          createdAt: try $0.createdAt().value ?? Date(),
          savedAt: try $0.savedAt().value ?? Date(),
          readingProgress: try $0.readingProgressPercent(),
          readingProgressAnchor: try $0.readingProgressAnchorIndex(),
          imageURLString: try $0.image(),
          onDeviceImageURLString: nil,
          documentDirectoryPath: nil,
          pageURLString: try $0.url(),
          descriptionText: try $0.description(),
          publisherURLString: try $0.originalArticleUrl(),
          author: try $0.author(),
          publishDate: try $0.publishedAt()?.value,
          slug: try $0.slug(),
          isArchived: try $0.isArchived(),
          contentReader: try $0.contentReader().rawValue,
          labels: try $0.labels(selection: feedItemLabelSelection.list.nullable) ?? []
        ),
        htmlContent: try $0.content(),
        highlights: try $0.highlights(selection: highlightSelection.list),
        contentStatus: try $0.state()
      )
    }

    let selection = Selection<QueryResult, Unions.ArticleResult> {
      try $0.on(
        articleError: .init {
          QueryResult.error(error: try $0.errorCodes().description)
        },
        articleSuccess: .init {
          QueryResult.success(result: try $0.article(selection: articleSelection))
        }
      )
    }

    let query = Selection.Query {
      // backend has a hack that allows us to pass in itemID in place of slug
      try $0.article(slug: itemID, username: username, selection: selection)
    }

    let path = appEnvironment.graphqlPath
    let headers = networker.defaultHeaders

    return try await withCheckedThrowingContinuation { continuation in
      send(query, to: path, headers: headers) { [weak self] queryResult in
        guard let payload = try? queryResult.get() else {
          continuation.resume(throwing: ContentFetchError.network)
          return
        }

        switch payload.data {
        case let .success(result: result):
          // Default to suceeded since older links will return a nil status
          // (but the content is almost always there)
          let status = result.contentStatus ?? .succeeded
          if status == .failed {
            continuation.resume(throwing: ContentFetchError.badData)
            return
          }

          if status == .succeeded {
            self?.persistArticleContent(
              item: result.item,
              htmlContent: result.htmlContent,
              highlights: result.highlights
            )
          }

          let articleContent = ArticleContent(
            htmlContent: result.htmlContent,
            highlightsJSONString: result.highlights.asJSONString,
            contentStatus: .make(from: result.contentStatus)
          )

          continuation.resume(returning: articleContent)
        case .error:
          continuation.resume(throwing: ContentFetchError.badData)
        }
      }
    }
  }

  func persistArticleContent(item: InternalLinkedItem, htmlContent: String, highlights: [InternalHighlight]) {
    backgroundContext.perform { [weak self] in
      guard let self = self else { return }
      let fetchRequest: NSFetchRequest<Models.LinkedItem> = LinkedItem.fetchRequest()
      fetchRequest.predicate = NSPredicate(format: "id == %@", item.id)

      let linkedItem = try? self.backgroundContext.fetch(fetchRequest).first

      guard let linkedItem = linkedItem else { return }

      let highlightObjects = highlights.map {
        $0.asManagedObject(context: self.backgroundContext)
      }
      linkedItem.addToHighlights(NSSet(array: highlightObjects))
      linkedItem.htmlContent = htmlContent
      linkedItem.id = item.id
      linkedItem.title = item.title
      linkedItem.createdAt = item.createdAt
      linkedItem.savedAt = item.savedAt
      linkedItem.readingProgress = item.readingProgress
      linkedItem.readingProgressAnchor = Int64(item.readingProgressAnchor)
      linkedItem.imageURLString = item.imageURLString
      linkedItem.onDeviceImageURLString = item.onDeviceImageURLString
      linkedItem.pageURLString = item.pageURLString
      linkedItem.descriptionText = item.descriptionText
      linkedItem.publisherURLString = item.publisherURLString
      linkedItem.author = item.author
      linkedItem.publishDate = item.publishDate
      linkedItem.slug = item.slug
      linkedItem.isArchived = item.isArchived
      linkedItem.contentReader = item.contentReader

      if linkedItem.isPDF {
        self.fetchPDFData(slug: linkedItem.unwrappedSlug, pageURLString: linkedItem.unwrappedPageURLString)
      }

      do {
        try self.backgroundContext.save()
        print("ArticleContent saved succesfully")
      } catch {
        self.backgroundContext.rollback()
        print("Failed to save ArticleContent: \(error)")
      }
    }
  }

  func fetchPDFData(slug: String, pageURLString: String) {
    Task {
      guard let url = URL(string: pageURLString) else { return }
      let result: (Data, URLResponse)? = try? await URLSession.shared.data(from: url)
      guard let httpResponse = result?.1 as? HTTPURLResponse, 200 ..< 300 ~= httpResponse.statusCode else { return }
      guard let data = result?.0 else { return }

      await backgroundContext.perform { [weak self] in
        let fetchRequest: NSFetchRequest<Models.LinkedItem> = LinkedItem.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "%K == %@", #keyPath(LinkedItem.slug), slug)

        let linkedItem = try? self?.backgroundContext.fetch(fetchRequest).first
        guard let linkedItem = linkedItem else { return }
        linkedItem.pdfData = data

        do {
          try self?.backgroundContext.save()
          print("PDF data saved succesfully")
        } catch {
          self?.backgroundContext.rollback()
          print("Failed to save PDF data: \(error)")
        }
      }
    }
  }

  func cachedArticleContent(itemID: String) async -> ArticleContent? {
    let linkedItemFetchRequest: NSFetchRequest<Models.LinkedItem> = LinkedItem.fetchRequest()
    linkedItemFetchRequest.predicate = NSPredicate(
      format: "id == %@", itemID
    )

    let context = backgroundContext

    return await context.perform(schedule: .immediate) {
      guard let linkedItem = try? context.fetch(linkedItemFetchRequest).first else { return nil }
      guard let htmlContent = linkedItem.htmlContent else { return nil }

      let highlights = linkedItem
        .highlights
        .asArray(of: Highlight.self)
        .filter { $0.serverSyncStatus != ServerSyncStatus.needsDeletion.rawValue }

      return ArticleContent(
        htmlContent: htmlContent,
        highlightsJSONString: highlights.map { InternalHighlight.make(from: $0) }.asJSONString,
        contentStatus: .succeeded
      )
    }
  }
}

private extension ArticleContentStatus {
  static func make(from savingRequestStatus: Enums.ArticleSavingRequestStatus?) -> ArticleContentStatus {
    guard let savingRequestStatus = savingRequestStatus else { return .unknown }

    switch savingRequestStatus {
    case .failed:
      return .failed
    case .processing:
      return .processing
    case .succeeded:
      return .succeeded
    }
  }
}
