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

struct BSAppsView: View {
	var title: String = "Apps"

	@StateObject private var _viewModel = SourcesViewModel.shared

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	@State private var _index: [BSAppItem] = []
	@State private var _isIndexing = true
	@State private var _query = ""

	private var _displayed: [BSAppItem] {
		let query = _query.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !query.isEmpty else { return _index }

		// Keep global Apps search on the same actor/path as SourceAppsView.
		// BSAppItem contains AltSource (a Core Data managed object), so passing the
		// catalogue through Task.detached is unsafe and behaved differently on
		// iOS 26. Filtering synchronously also makes global and per-source search
		// use exactly the same proven code path.
		return BSAppIndex.filter(_index, query: query)
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
					ScrollView {
						WSEmptyState(
							icon: "magnifyingglass",
							title: "No Matches",
							message: "No app matches “\(_query)”."
						)
						.padding(.horizontal, 16)
						.padding(.top, 40)
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
	}

	// MARK: Indexing

	private func _buildIndex() async {
		_isIndexing = true
		defer { _isIndexing = false }

		if _sources.isEmpty {
			_index = []
			return
		}

		let sources = Array(_sources)

		if sources.contains(where: { _viewModel.sources[$0] == nil }) {
			await _viewModel.fetchSources(_sources)
		}

		let key = _indexKey
		if let cached = BSAppIndex.cached(for: key) {
			_index = cached
			return
		}

		let items = BSAppIndex.build(sources: sources, repositories: _viewModel.sources)

		if !items.isEmpty || sources.isEmpty {
			BSAppIndex.cache(items, for: key)
		}
		_index = items
	}
}
