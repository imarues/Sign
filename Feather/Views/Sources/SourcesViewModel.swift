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

	static func fetch(from url: URL, forceReload: Bool) async -> ASRepository? {
		do {
			var request = URLRequest(url: url)
			request.timeoutInterval = 35
			request.cachePolicy = forceReload ? .reloadIgnoringLocalCacheData : .useProtocolCachePolicy

			let (data, response) = try await URLSession.shared.data(for: request)
			if let response = response as? HTTPURLResponse,
			   !(200...299).contains(response.statusCode) {
				return nil
			}

			let repository = try JSONDecoder().decode(ASRepository.self, from: data)
			store(data, for: url)
			return repository
		} catch {
			return nil
		}
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

	/// Different tabs and newly added sources may request their feeds together.
	/// Deduplicate the actual network request by URL, not by a single global
	/// fetch that delays every new source behind one slow catalogue.
	private var _networkTasks: [URL: Task<ASRepository?, Never>] = [:]
	private var _activeFetchCalls = 0

	private func _networkTask(for url: URL) -> Task<ASRepository?, Never> {
		if let task = _networkTasks[url] { return task }
		let task = Task.detached(priority: .userInitiated) {
			await BSRepositoryDiskCache.fetch(from: url, forceReload: true)
		}
		_networkTasks[url] = task
		return task
	}

	private func _apply(_ repository: ASRepository, to source: AltSource) {
		sources[source] = repository
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

		if !refresh {
			// Use the disk copy without waiting for *all* cache reads.
			await withTaskGroup(of: (URL, ASRepository?).self) { group in
				for (_, url) in sourcesArray {
					group.addTask { (url, BSRepositoryDiskCache.load(from: url)) }
				}
				for await (url, repository) in group {
					guard let repository else { continue }
					for pair in sourcesArray where pair.url == url {
						if self.sources[pair.source] == nil {
							self._apply(repository, to: pair.source)
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

			await withTaskGroup(of: (URL, ASRepository?).self) { group in
				for item in tasks {
					group.addTask { (item.url, await item.task.value) }
				}
				for await (url, repository) in group {
					if let repository {
						for pair in batch where pair.url == url {
							self._apply(repository, to: pair.source)
						}
					}
					// A failed refresh keeps its previously cached catalogue.
					_networkTasks[url] = nil
				}
			}
		}
	}
}
