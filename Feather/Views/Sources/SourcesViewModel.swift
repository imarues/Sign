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

	private var _fetchTask: Task<Void, Never>?

	/// Fetch the repositories behind `sources`.
	///
	/// Cold launch first restores the most recent successful copy from disk so
	/// the three storefront tabs can draw immediately. The real source is then
	/// refreshed in the background and atomically replaces that copy.
	func fetchSources(
		_ requestedSources: some Collection<AltSource>,
		refresh: Bool = false,
		batchSize: Int = 4
	) async {
		let requested = Array(requestedSources)

		// All storefront tabs share this model. Previously a second tab simply
		// returned when another tab happened to own the fetch, which left that
		// caller with a partial/empty catalogue. Wait for the shared fetch instead.
		if !isFinished {
			await _fetchTask?.value
			if !refresh, requested.allSatisfy({ self.sources[$0] != nil }) {
				return
			}
		}

		if !refresh, requested.allSatisfy({ self.sources[$0] != nil }) {
			return
		}

		isFinished = false
		let task = Task { @MainActor in
			defer {
				isFinished = true
				_fetchTask = nil
			}
			await _performFetch(requested, refresh: refresh, batchSize: max(1, batchSize))
		}
		_fetchTask = task
		await task.value
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

		// Never blank a catalogue that is already on screen. On a normal cold
		// launch restore missing repositories from disk first; pull-to-refresh
		// deliberately keeps the current rows visible while the new JSON arrives.
		if !refresh {
			let missingURLs = sourcesArray.compactMap { pair in
				self.sources[pair.source] == nil ? pair.url : nil
			}

			let cached = await withTaskGroup(
				of: (URL, ASRepository?).self,
				returning: [URL: ASRepository].self
			) { group in
				for url in missingURLs {
					group.addTask {
						(url, BSRepositoryDiskCache.load(from: url))
					}
				}

				var result: [URL: ASRepository] = [:]
				for await (url, repository) in group {
					if let repository { result[url] = repository }
				}
				return result
			}

			for (source, url) in sourcesArray {
				guard self.sources[source] == nil, let repository = cached[url] else { continue }
				self.sources[source] = repository
				revision &+= 1
			}
		}

		// Always refresh the requested repositories after restoring the cache.
		// Work is concurrent within each small batch so one slow source cannot
		// serially hold every other source behind it.
		for startIndex in stride(from: 0, to: sourcesArray.count, by: batchSize) {
			let endIndex = min(startIndex + batchSize, sourcesArray.count)
			let batch = Array(sourcesArray[startIndex..<endIndex])

			let fetched = await withTaskGroup(
				of: (URL, ASRepository?).self,
				returning: [URL: ASRepository].self
			) { group in
				for (_, url) in batch {
					group.addTask {
						let repository = await BSRepositoryDiskCache.fetch(
							from: url,
							forceReload: true
						)
						return (url, repository)
					}
				}

				var result: [URL: ASRepository] = [:]
				for await (url, repository) in group {
					if let repository { result[url] = repository }
				}
				return result
			}

			for (source, url) in batch {
				// Network/parsing failure intentionally leaves the last good cache
				// on screen instead of turning a source into an empty catalogue.
				guard let repository = fetched[url] else { continue }
				self.sources[source] = repository
				revision &+= 1
			}
		}
	}
}
