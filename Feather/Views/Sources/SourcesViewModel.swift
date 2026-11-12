//
//  SourcesViewModel.swift
//  Feather
//
//  Created by samara on 30.04.2025.
//

import Foundation
import AltSourceKit
import SwiftUI

// MARK: - Persistent source cache
/// Keeps the last successfully decoded JSON for each source on disk.
///
/// A catalogue can be several megabytes. Waiting for the network and JSON
/// decoding on every cold launch made Today, Sources and Apps all look empty
/// for seconds. The cached repository is shown first, then a network refresh
/// replaces it when it arrives.
private enum BSRepositoryDiskCache {
	private static var directory: URL? {
		guard let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
			return nil
		}
		return root.appendingPathComponent("BatSignSourceRepositories", isDirectory: true)
	}

	/// A deterministic, short filename for an arbitrary source URL.
	private static func filename(for url: URL) -> String {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for byte in url.absoluteString.utf8 {
			hash ^= UInt64(byte)
			hash &*= 1_099_511_628_211
		}
		return String(hash, radix: 16) + ".json"
	}

	private static func fileURL(for url: URL) -> URL? {
		directory?.appendingPathComponent(filename(for: url), isDirectory: false)
	}

	static func load(from url: URL) -> ASRepository? {
		guard let file = fileURL(for: url),
		      let data = try? Data(contentsOf: file) else {
			return nil
		}
		return try? JSONDecoder().decode(ASRepository.self, from: data)
	}

	static func store(_ data: Data, for url: URL) {
		guard let directory, let file = fileURL(for: url) else { return }
		do {
			try FileManager.default.createDirectory(
				at: directory,
				withIntermediateDirectories: true,
				attributes: nil
			)
			try data.write(to: file, options: .atomic)
		} catch {
			// The cache is an acceleration only. A cache write must never make a
			// perfectly usable source fail.
		}
	}

	struct FetchOutcome: Sendable {
		let repository: ASRepository?
		let uniqueAppCount: Int?
		let failure: String?

		static func success(_ repository: ASRepository) -> Self {
			// Count in the background with the same rules as the displayed list.
			.init(repository: repository,
			      uniqueAppCount: BSAppIndex.uniqueCount(in: repository),
			      failure: nil)
		}
		static func error(_ message: String) -> Self {
			.init(repository: nil, uniqueAppCount: nil, failure: message)
		}
	}

	static func fetch(from url: URL, forceReload: Bool) async -> FetchOutcome {
		// A large raw.githubusercontent.com feed can be valid but slow. Retry
		// transient transport errors once; do not spin on bad JSON/404 links.
		for attempt in 0..<2 {
			do {
				var request = URLRequest(url: url)
				request.timeoutInterval = 55
				request.cachePolicy = forceReload
					? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy
				request.setValue("application/json, */*", forHTTPHeaderField: "Accept")

				let (data, response) = try await URLSession.shared.data(for: request)
				if let response = response as? HTTPURLResponse,
				   !(200...299).contains(response.statusCode) {
					if (response.statusCode == 429 || response.statusCode >= 500), attempt == 0 {
						try? await Task.sleep(nanoseconds: 850_000_000)
						continue
					}
					return .error("HTTP \(response.statusCode) — check the source URL.")
				}
				guard !data.isEmpty else { return .error("The source returned an empty response.") }
				do {
					let repository = try JSONDecoder().decode(ASRepository.self, from: data)
					store(data, for: url)
					return .success(repository)
				} catch {
					return .error("Source JSON could not be read: \(error.localizedDescription)")
				}
			} catch {
				if attempt == 0 {
					try? await Task.sleep(nanoseconds: 850_000_000)
					continue
				}
				return .error("Network error: \(error.localizedDescription)")
			}
		}
		return .error("Source could not be refreshed.")
	}

}

// MARK: - Class
/// Holds the repository of every fetched source.
///
/// Main-actor bound, because `sources` is keyed by `AltSource` — a `viewContext`
/// object — while network/cache work is performed away from the UI actor.
@MainActor
final class SourcesViewModel: ObservableObject {
	static let shared = SourcesViewModel()

	@Published private(set) var isFinished = true
	@Published private(set) var revision = 0
	@Published var sources: [AltSource: ASRepository] = [:]
	@Published private(set) var distinctAppCounts: [URL: Int] = [:]
	@Published private(set) var sourceFailures: [URL: String] = [:]
	@Published private(set) var loadingURLs: Set<URL> = []

	func failure(for source: AltSource) -> String? {
		guard let url = source.sourceURL else { return "Missing source URL." }
		return sourceFailures[url]
	}

	func isFetching(_ source: AltSource) -> Bool {
		guard let url = source.sourceURL else { return false }
		return loadingURLs.contains(url)
	}

	/// Different tabs and newly added sources may request their feeds together.
	/// Deduplicate the actual network request by URL, not by a single global
	/// fetch that delays every new source behind one slow catalogue.
	private var _networkTasks: [URL: Task<BSRepositoryDiskCache.FetchOutcome, Never>] = [:]
	private var _activeFetchCalls = 0

	private func _networkTask(for url: URL) -> Task<BSRepositoryDiskCache.FetchOutcome, Never> {
		if let task = _networkTasks[url] { return task }
		let task = Task.detached(priority: .userInitiated) {
			await BSRepositoryDiskCache.fetch(from: url, forceReload: true)
		}
		_networkTasks[url] = task
		return task
	}

	private func _apply(_ repository: ASRepository, to source: AltSource, uniqueAppCount: Int) {
		sources[source] = repository
		if let url = source.sourceURL {
			sourceFailures[url] = nil
			distinctAppCounts[url] = uniqueAppCount
		}
		revision &+= 1
		// A source is visible immediately after saving its URL. Replace the
		// temporary hostname and icon as soon as its first fetch succeeds.
		if let name = repository.name, !name.isEmpty, source.name != name {
			source.name = name
		}
		if let icon = repository.currentIconURL, source.iconURL != icon {
			source.iconURL = icon
		}
		if Storage.shared.context.hasChanges {
			try? Storage.shared.context.save()
		}
	}

	/// Restore previously cached feeds immediately, then update each source
	/// independently as its own network request completes. A slow or broken
	/// second feed must not block the primary one (or vice versa).
	func fetchSources(
		_ requestedSources: some Collection<AltSource>,
		refresh: Bool = false,
		batchSize: Int = 4
	) async {
		let requested = Array(requestedSources)
		let targets = requested.filter { refresh || sources[$0] == nil }
		guard !targets.isEmpty else { return }

		_activeFetchCalls += 1
		isFinished = false
		defer {
			_activeFetchCalls -= 1
			isFinished = _activeFetchCalls == 0
		}

		await _performFetch(targets, refresh: refresh, batchSize: max(1, batchSize))
	}

	private func _performFetch(
		_ requested: [AltSource],
		refresh: Bool,
		batchSize: Int
	) async {
		let sourcesArray: [(source: AltSource, url: URL)] = requested.compactMap { source in
			guard let url = source.sourceURL else { return nil }
			return (source, url)
		}
		for item in sourcesArray { loadingURLs.insert(item.url) }
		defer { for item in sourcesArray { loadingURLs.remove(item.url) } }

		if !refresh {
			// Use the disk copy without waiting for *all* cache reads.
			await withTaskGroup(of: (URL, ASRepository?, Int?).self) { group in
				for (_, url) in sourcesArray {
					group.addTask {
						let repository = BSRepositoryDiskCache.load(from: url)
						return (url, repository, repository.map { BSAppIndex.uniqueCount(in: $0) })
					}
				}
				for await (url, repository, uniqueAppCount) in group {
					guard let repository, let uniqueAppCount else { continue }
					for pair in sourcesArray where pair.url == url {
						if self.sources[pair.source] == nil {
							self._apply(repository, to: pair.source, uniqueAppCount: uniqueAppCount)
						}
					}
				}
			}
		}

		// Request up to batchSize feeds at once, and publish *each* result as
		// soon as it comes back. Previously we gathered the entire batch into
		// a dictionary before showing any of its sources.
		for index in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(index + batchSize, sourcesArray.count)
			let batch = Array(sourcesArray[index..<endIndex])
			let tasks = batch.map { (source: $0.source, url: $0.url, task: _networkTask(for: $0.url)) }

			await withTaskGroup(of: (URL, BSRepositoryDiskCache.FetchOutcome).self) { group in
				for item in tasks {
					group.addTask { (item.url, await item.task.value) }
				}
				for await (url, outcome) in group {
					if let repository = outcome.repository,
					   let uniqueAppCount = outcome.uniqueAppCount {
						for pair in batch where pair.url == url {
							self._apply(repository, to: pair.source, uniqueAppCount: uniqueAppCount)
						}
					} else {
						sourceFailures[url] = outcome.failure ?? "Source refresh failed."
					}
					loadingURLs.remove(url)
					// A failed refresh keeps the last successfully cached catalogue.
					_networkTasks[url] = nil
				}
			}
		}
	}
}
