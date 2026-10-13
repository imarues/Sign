//
//  BSAppsView.swift
//  Feather
//
//  BatSign's Apps surface: every app from every source, in BatSign's row shape,
//  with the same list backing the search tab.
//

import SwiftUI
import CoreData
import AltSourceKit
import NimbleViews

// MARK: - Lightweight global-search index

/// A search-only snapshot. It deliberately contains no Core Data objects and no
/// repository/app model values, so it is safe to move off the main actor.
private struct BSAppsSearchRecord: Sendable {
	let id: String
	let name: String
	let bundle: String
	let developer: String
	let category: String
	let subtitle: String
	let source: String
	let haystack: String
}

private enum BSAppsSearchEngine {
	/// Build once per catalogue revision. Expensive normalization never happens
	/// while the user is typing.
	static func makeRecords(from items: [BSAppItem]) -> [BSAppsSearchRecord] {
		items.map { item in
			let name = _normalized(item.app.currentName)
			let bundle = _normalized(item.app.id ?? "")
			let developer = _normalized(item.app.developer ?? "")
			let category = _normalized(item.app.category ?? "")
			let subtitle = _normalized(item.app.subtitle ?? "")
			let source = _normalized(item.source.name ?? item.storedSource.name ?? "")
			let haystack = [name, bundle, developer, category, subtitle, source]
				.filter { !$0.isEmpty }
				.joined(separator: " ")

			return BSAppsSearchRecord(
				id: item.id,
				name: name,
				bundle: bundle,
				developer: developer,
				category: category,
				subtitle: subtitle,
				source: source,
				haystack: haystack
			)
		}
	}

	/// Search only immutable strings. Descriptions are intentionally excluded:
	/// they can be very large and were the main source of per-keystroke CPU and
	/// memory churn in the global Apps/Search tabs.
	static func search(_ records: [BSAppsSearchRecord], query: String, limit: Int = 120) -> [String] {
		let wanted = _normalized(query)
		guard !wanted.isEmpty, limit > 0 else { return [] }

		let tokens = wanted.split(separator: " ").map(String.init)
		var matches: [(score: Int, name: String, id: String)] = []
		matches.reserveCapacity(min(records.count, max(limit, 64)))

		for record in records {
			guard tokens.allSatisfy({ record.haystack.contains($0) }) else { continue }

			var score = 0

			if record.name == wanted {
				score += 100_000
			} else if record.name.hasPrefix(wanted) {
				score += 90_000
			} else if _wordStarts(record.name, with: wanted) {
				score += 85_000
			} else if record.name.contains(wanted) {
				score += 80_000
			}

			if record.bundle == wanted { score += 70_000 }
			else if record.bundle.hasPrefix(wanted) { score += 55_000 }
			else if record.bundle.contains(wanted) { score += 45_000 }

			if record.developer == wanted { score += 35_000 }
			else if record.developer.hasPrefix(wanted) { score += 30_000 }
			else if record.developer.contains(wanted) { score += 25_000 }

			if record.category == wanted { score += 18_000 }
			else if record.category.contains(wanted) { score += 12_000 }

			if record.subtitle.contains(wanted) { score += 10_000 }
			if record.source.contains(wanted) { score += 8_000 }

			for token in tokens {
				if record.name.hasPrefix(token) { score += 2_000 }
				else if _wordStarts(record.name, with: token) { score += 1_700 }
				else if record.name.contains(token) { score += 1_300 }
				else if record.bundle.contains(token) { score += 700 }
				else if record.developer.contains(token) { score += 350 }
				else if record.category.contains(token) { score += 180 }
				else { score += 50 }
			}

			matches.append((score, record.name, record.id))
		}

		matches.sort { lhs, rhs in
			if lhs.score != rhs.score { return lhs.score > rhs.score }
			if lhs.name != rhs.name { return lhs.name < rhs.name }
			return lhs.id < rhs.id
		}

		return Array(matches.prefix(limit).map(\.id))
	}

	private static func _wordStarts(_ text: String, with query: String) -> Bool {
		text.split(separator: " ").contains { $0.hasPrefix(query) }
	}

	private static func _normalized(_ raw: String) -> String {
		let folded = raw.folding(
			options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
			locale: .current
		)
		let cleaned = folded.map { character -> Character in
			(character.isLetter || character.isNumber) ? character : " "
		}
		return String(cleaned)
			.split(whereSeparator: { $0.isWhitespace })
			.joined(separator: " ")
	}
}

struct BSAppsView: View {
	var title: String = "Apps"

	@StateObject private var _viewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	@State private var _index: [BSAppItem] = []
	@State private var _itemsByID: [String: BSAppItem] = [:]
	@State private var _searchIndex: [BSAppsSearchRecord] = []
	@State private var _results: [BSAppItem] = []
	@State private var _isIndexing = true
	@State private var _isFiltering = false
	@State private var _query = ""
	@State private var _searchWorker: Task<[String], Never>?

	private var _trimmedQuery: String {
		_query.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var _isSearching: Bool {
		!_trimmedQuery.isEmpty
	}

	private var _displayed: [BSAppItem] {
		_isSearching ? _results : _index
	}

	private var _isLoadingCatalogue: Bool {
		guard _index.isEmpty, !_sources.isEmpty else { return false }
		return _sources.contains { _viewModel.sources[$0] == nil }
	}

	private var _indexKey: String {
		let identifiers = _sources.map { $0.identifier ?? $0.sourceURL?.absoluteString ?? "" }
		let loaded = _sources.map { source -> String in
			let count = _viewModel.sources[source]?.apps.count ?? -1
			return "\(source.identifier ?? source.sourceURL?.absoluteString ?? "")#\(count)"
		}
		return identifiers.joined(separator: ",")
			+ "||" + loaded.joined(separator: ",")
			+ "||revision:\(_viewModel.revision)"
	}

	var body: some View {
		NavigationStack {
			Group {
				if (_isIndexing || _isLoadingCatalogue) && _index.isEmpty {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else if _index.isEmpty {
					ScrollView {
						WSEmptyState(
							icon: "square.grid.2x2",
							title: "No Apps Yet",
							message: "Add a source and its apps will show up here."
						)
						.padding(.horizontal, 16)
						.padding(.top, 40)
					}
				} else if _displayed.isEmpty {
					if _isFiltering && _isSearching {
						ProgressView()
							.frame(maxWidth: .infinity, maxHeight: .infinity)
					} else {
						ScrollView {
							WSEmptyState(
								icon: "magnifyingglass",
								title: "No Matches",
								message: "No app matches “\(_query)”."
							)
							.padding(.horizontal, 16)
							.padding(.top, 40)
						}
					}
				} else {
					ScrollView {
						BSAppList(items: _displayed)
							.padding(.top, 4)
							.padding(.bottom, 28)
					}
					.scrollIndicators(.hidden)
				}
			}
			.bsScreen()
			.navigationTitle(title)
			.navigationBarTitleDisplayMode(.large)
			.searchable(
				text: $_query,
				placement: .navigationBarDrawer(displayMode: .always),
				prompt: Text("Apps, developers")
			)
			.refreshable {
				await _viewModel.fetchSources(_sources, refresh: true)
			}
		}
		.task(id: _indexKey) {
			await _buildIndex()
		}
		.onChange(of: _query) { newValue in
			_scheduleSearch(newValue)
		}
		.onDisappear {
			_searchWorker?.cancel()
		}
	}

	// MARK: Indexing

	private func _buildIndex() async {
		_isIndexing = true
		defer { _isIndexing = false }

		if _sources.isEmpty {
			_applyIndex([])
			return
		}

		let sources = Array(_sources)

		if sources.contains(where: { _viewModel.sources[$0] == nil }) {
			await _viewModel.fetchSources(_sources)
		}

		let key = _indexKey
		if let cached = BSAppIndex.cached(for: key) {
			_applyIndex(cached)
			return
		}

		let items = BSAppIndex.build(sources: sources, repositories: _viewModel.sources)

		if !items.isEmpty || sources.isEmpty {
			BSAppIndex.cache(items, for: key)
		}
		_applyIndex(items)
	}

	/// Convert the catalogue to its search-only representation once, on the main
	/// actor where AltSource/Core Data values are valid. Search never touches the
	/// model objects after this point.
	private func _applyIndex(_ items: [BSAppItem]) {
		_index = items

		var byID: [String: BSAppItem] = [:]
		byID.reserveCapacity(items.count)
		for item in items {
			byID[item.id] = item
		}
		_itemsByID = byID
		_searchIndex = BSAppsSearchEngine.makeRecords(from: items)

		_scheduleSearch(_query)
	}

	/// Debounce typing, then search the immutable string snapshot on a detached
	/// task. Cancelling a query cancels its worker, so rapid typing cannot stack
	/// multiple expensive searches behind the UI.
	private func _scheduleSearch(_ text: String) {
		_searchWorker?.cancel()

		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			_results = []
			_isFiltering = false
			return
		}

		let records = _searchIndex
		guard !records.isEmpty else {
			_results = []
			_isFiltering = false
			return
		}

		_isFiltering = true

		let worker = Task.detached(priority: .userInitiated) { () -> [String] in
			try? await Task.sleep(nanoseconds: 90_000_000)
			guard !Task.isCancelled else { return [] }

			let ids = BSAppsSearchEngine.search(records, query: trimmed)
			guard !Task.isCancelled else { return [] }
			return ids
		}
		_searchWorker = worker

		Task { @MainActor in
			let ids = await worker.value
			guard !worker.isCancelled else { return }
			guard _query.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

			_results = ids.compactMap { _itemsByID[$0] }
			_isFiltering = false
		}
	}
}
