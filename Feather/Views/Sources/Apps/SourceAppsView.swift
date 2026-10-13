//
//  SourceAppsView.swift
//  Feather
//
//  One source's catalogue. Large sources are indexed once and searched through
//  a lightweight string snapshot so typing never rebuilds the repository.
//

import SwiftUI
import AltSourceKit
import NimbleViews
import UIKit

// MARK: - Lightweight per-source search

private struct SourceAppsSearchRecord: Sendable {
	let id: String
	let name: String
	let bundle: String
	let developer: String
	let category: String
	let subtitle: String
	let haystack: String
}

private enum SourceAppsSearchEngine {
	static func makeRecords(from items: [BSAppItem]) -> [SourceAppsSearchRecord] {
		items.map { item in
			let name = _normalized(item.app.currentName)
			let bundle = _normalized(item.app.id ?? "")
			let developer = _normalized(item.app.developer ?? "")
			let category = _normalized(item.app.category ?? "")
			let subtitle = _normalized(item.app.subtitle ?? "")
			let haystack = [name, bundle, developer, category, subtitle]
				.filter { !$0.isEmpty }
				.joined(separator: " ")

			return SourceAppsSearchRecord(
				id: item.id,
				name: name,
				bundle: bundle,
				developer: developer,
				category: category,
				subtitle: subtitle,
				haystack: haystack
			)
		}
	}

	static func search(_ records: [SourceAppsSearchRecord], query: String, limit: Int = 200) -> [String] {
		let wanted = _normalized(query)
		guard !wanted.isEmpty, limit > 0 else { return [] }

		let tokens = wanted.split(separator: " ").map(String.init)
		var matches: [(score: Int, name: String, id: String)] = []
		matches.reserveCapacity(min(records.count, max(limit, 64)))

		for record in records {
			guard !Task<Never, Never>.isCancelled else { return [] }
			guard tokens.allSatisfy({ record.haystack.contains($0) }) else { continue }

			var score = 0
			if record.name == wanted { score += 100_000 }
			else if record.name.hasPrefix(wanted) { score += 90_000 }
			else if _wordStarts(record.name, with: wanted) { score += 85_000 }
			else if record.name.contains(wanted) { score += 80_000 }

			if record.bundle == wanted { score += 70_000 }
			else if record.bundle.hasPrefix(wanted) { score += 55_000 }
			else if record.bundle.contains(wanted) { score += 45_000 }

			if record.developer == wanted { score += 35_000 }
			else if record.developer.hasPrefix(wanted) { score += 30_000 }
			else if record.developer.contains(wanted) { score += 25_000 }

			if record.category == wanted { score += 18_000 }
			else if record.category.contains(wanted) { score += 12_000 }
			if record.subtitle.contains(wanted) { score += 10_000 }

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

// MARK: - Sort
extension SourceAppsView {
	enum SortOption: String, CaseIterable {
		case `default` = "default"
		case name
		case date

		var displayName: String {
			switch self {
			case .default:	.localized("Default")
			case .name:		.localized("Name")
			case .date:		.localized("Date")
			}
		}
	}
}

// MARK: - View
struct SourceAppsView: View {
	@AppStorage("Feather.sortOptionRawValue") private var _sortOptionRawValue: String = SortOption.default.rawValue
	@AppStorage("Feather.sortAscending") private var _sortAscending: Bool = true

	@State private var _sortOption: SortOption = .default
	@State private var _searchText = ""
	@State private var _sourceContexts: [SourceRepositoryContext]?
	@State private var _catalogueItems: [BSAppItem] = []
	@State private var _items: [BSAppItem] = []
	@State private var _itemsByID: [String: BSAppItem] = [:]
	@State private var _searchIndex: [SourceAppsSearchRecord] = []
	@State private var _searchWorker: Task<[String], Never>?
	@State private var _isFiltering = false

	@ObservedObject private var _bulk = BSBulkSign.shared

	@State private var _isSelecting = false
	@State private var _selection: Set<String> = []

	var object: [AltSource]
	@ObservedObject var viewModel: SourcesViewModel

	private var _trimmedSearch: String {
		_searchText.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private var _navigationTitle: String {
		if object.count == 1 {
			object.first?.name ?? .localized("Unknown")
		} else {
			.localized("%lld Sources", arguments: object.count)
		}
	}

	// MARK: Body
	var body: some View {
		Group {
			if _sourceContexts == nil, !viewModel.isFinished {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			} else if _items.isEmpty {
				if _isFiltering && !_trimmedSearch.isEmpty {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				} else {
					ScrollView {
						WSEmptyState(
							icon: _trimmedSearch.isEmpty ? "square.grid.2x2" : "magnifyingglass",
							title: _trimmedSearch.isEmpty ? "No Apps" : "No Matches",
							message: _trimmedSearch.isEmpty
								? "This source has not published any apps yet."
								: "No app matches “\(_searchText)”."
						)
						.padding(.horizontal, 16)
						.padding(.top, 40)
					}
				}
			} else {
				ScrollView {
					VStack(alignment: .leading, spacing: 16) {
						BSBulkSignStrip()
						BSAppList(items: _items, picking: _isSelecting ? $_selection : nil)
					}
					.padding(.top, 4)
					.padding(.bottom, 28)
				}
				.scrollIndicators(.hidden)
			}
		}
		.bsScreen()
		.safeAreaInset(edge: .bottom) {
			if _isSelecting {
				BSBulkActionBar(
					count: _selection.count,
					title: _bulkTitle,
					action: _startBulkDownload,
					selectAll: _toggleSelectAll,
					cancel: _endSelecting
				)
			}
		}
		.animation(.snappy(duration: 0.22), value: _isSelecting)
		.navigationTitle(_navigationTitle)
		.navigationBarTitleDisplayMode(.large)
		.toolbar(.visible, for: .navigationBar)
		.searchable(
			text: $_searchText,
			placement: .navigationBarDrawer(displayMode: .always),
			prompt: Text("Apps, developers")
		)
		.toolbarTitleMenu {
			if let first = _sourceContexts?.first, object.count == 1 {
				if let url = first.repository.website {
					Button(.localized("Visit Website"), systemImage: "globe") {
						UIApplication.open(url)
					}
				}

				if let url = first.repository.patreonURL {
					Button(.localized("Visit Patreon"), systemImage: "dollarsign.circle") {
						UIApplication.open(url)
					}
				}
			}

			Divider()

			Button(.localized("Copy"), systemImage: "doc.on.doc") {
				guard !object.isEmpty else {
					UIAlertController.showAlertWithOk(
						title: .localized("Error"),
						message: .localized("No sources to copy")
					)
					return
				}
				UIPasteboard.general.string = object.compactMap {
					$0.sourceURL?.absoluteString
				}.joined(separator: "\n")
				UIAlertController.showAlertWithOk(
					title: .localized("Success"),
					message: .localized("Sources copied to clipboard")
				)
			}
		}
		.toolbar {
			ToolbarItem(placement: .topBarLeading) {
				if !_items.isEmpty && !_isFiltering {
					Button(_isSelecting ? "Done" : "Select") {
						BSHaptics.tap()
						withAnimation(.snappy(duration: 0.22)) {
							_isSelecting.toggle()
							if !_isSelecting { _selection.removeAll() }
						}
					}
					.font(.body.weight(_isSelecting ? .semibold : .regular))
				}
			}

			NBToolbarMenu(
				systemImage: "line.3.horizontal.decrease",
				style: .icon,
				placement: .topBarTrailing
			) {
				_sortActions()
			}
		}
		.onAppear {
			_sortOption = SortOption(rawValue: _sortOptionRawValue) ?? .default
			_load()
		}
		.onChange(of: viewModel.isFinished) { _ in
			_load()
		}
		.onChange(of: viewModel.revision) { _ in
			_load()
		}
		.onChange(of: _searchText) { newValue in
			_scheduleSearch(newValue)
		}
		.onChange(of: _sortOption) { newValue in
			_sortOptionRawValue = newValue.rawValue
			_refreshDisplayed()
		}
		.onChange(of: _sortAscending) { _ in
			_refreshDisplayed()
		}
		.onDisappear {
			_searchWorker?.cancel()
		}
	}

	// MARK: Loading/indexing

	private func _load() {
		let loadedSources = object.compactMap { source -> SourceRepositoryContext? in
			guard let repository = viewModel.sources[source] else { return nil }
			return SourceRepositoryContext(sourceURL: source.sourceURL, repository: repository)
		}

		guard loadedSources.count == object.count || viewModel.isFinished else { return }
		_sourceContexts = loadedSources

		let items = BSAppIndex.build(sources: object, repositories: viewModel.sources)
		_catalogueItems = items

		var byID: [String: BSAppItem] = [:]
		byID.reserveCapacity(items.count)
		for item in items {
			byID[item.id] = item
		}
		_itemsByID = byID

		_searchIndex = SourceAppsSearchEngine.makeRecords(from: items)
		_refreshDisplayed()
	}

	private func _refreshDisplayed() {
		if _trimmedSearch.isEmpty {
			_searchWorker?.cancel()
			_isFiltering = false
			_items = _sorted(_catalogueItems)
		} else {
			_scheduleSearch(_searchText)
		}
	}

	private func _scheduleSearch(_ text: String) {
		_searchWorker?.cancel()

		let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else {
			_isFiltering = false
			_items = _sorted(_catalogueItems)
			return
		}

		let records = _searchIndex
		guard !records.isEmpty else {
			_isFiltering = false
			_items = []
			return
		}

		_isFiltering = true
		_items = []

		let worker = Task.detached(priority: .userInitiated) { () -> [String] in
			try? await Task<Never, Never>.sleep(nanoseconds: 90_000_000)
			guard !Task<Never, Never>.isCancelled else { return [] }
			return SourceAppsSearchEngine.search(records, query: trimmed)
		}
		_searchWorker = worker

		Task { @MainActor in
			let ids = await worker.value
			guard !worker.isCancelled else { return }
			guard _searchText.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }

			let matches = ids.compactMap { _itemsByID[$0] }
			_items = _sorted(matches)
			_isFiltering = false
		}
	}

	private func _sorted(_ input: [BSAppItem]) -> [BSAppItem] {
		guard _sortOption != .default else { return input }
		var items = input

		switch _sortOption {
		case .default:
			break
		case .name:
			items.sort {
				$0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
			}
		case .date:
			items.sort {
				($0.app.currentDate?.date ?? .distantPast) < ($1.app.currentDate?.date ?? .distantPast)
			}
		}

		if !_sortAscending { items.reverse() }
		return items
	}

	struct SourceRepositoryContext {
		let sourceURL: URL?
		let repository: ASRepository
	}

	struct SourceAppRoute: Identifiable, Hashable {
		let sourceURL: URL?
		let source: ASRepository
		let app: ASRepository.App
		let id: String = UUID().uuidString
	}
}

// MARK: - Picking several

extension SourceAppsView {
	private var _pickedItems: [BSAppItem] {
		_items.filter { _selection.contains($0.id) }
	}

	private var _bulkTitle: String {
		_selection.count == 1 ? "Download & Sign 1 App" : "Download & Sign \(_selection.count) Apps"
	}

	private func _startBulkDownload() {
		let items = _pickedItems
		guard !items.isEmpty else { return }

		let started = BSBulkSign.shared.downloadAndSign(items, title: _bulkTitle)
		_endSelecting()

		if started == 0 {
			UINotificationFeedbackGenerator().notificationOccurred(.warning)
		}
	}

	private func _toggleSelectAll() {
		withAnimation(.snappy(duration: 0.2)) {
			if _selection.count >= _items.count {
				_selection.removeAll()
			} else {
				_selection = Set(_items.map(\.id))
			}
		}
	}

	private func _endSelecting() {
		withAnimation(.snappy(duration: 0.22)) {
			_isSelecting = false
			_selection.removeAll()
		}
	}
}

// MARK: - Extension: View (Sort)
extension SourceAppsView {
	@ViewBuilder
	private func _sortActions() -> some View {
		Section(.localized("Filter by")) {
			ForEach(SortOption.allCases, id: \.displayName) { opt in
				_sortButton(for: opt)
			}
		}
	}

	private func _sortButton(for option: SortOption) -> some View {
		Button {
			if _sortOption == option {
				_sortAscending.toggle()
			} else {
				_sortOption = option
				_sortAscending = true
			}
		} label: {
			HStack {
				Text(option.displayName)
				Spacer()
				if _sortOption == option {
					Image(systemName: _sortAscending ? "chevron.up" : "chevron.down")
				}
			}
		}
	}
}

extension View {
	@ViewBuilder
	func navigationDestinationIfAvailable<Item: Identifiable & Hashable, Destination: View>(
		item: Binding<Item?>,
		@ViewBuilder destination: @escaping (Item) -> Destination
	) -> some View {
		if #available(iOS 17, *) {
			self.navigationDestination(item: item, destination: destination)
		} else {
			self
		}
	}
}
