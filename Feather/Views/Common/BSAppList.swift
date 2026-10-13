//
//  BSAppList.swift
//  Feather
//
//  BatSign's Apps list: the row shape from the BatSign design — icon, name,
//  category underneath, GET pill on the trailing edge, hairline between rows —
//  and the flattened index that feeds it.
//
//  The index is the reason this file exists as its own type: the old search
//  walked every source and rebuilt an array of every app on *every* keystroke.
//  Here it is built once per source-set change and filtered in a plain loop.
//

import SwiftUI
import AltSourceKit
import NimbleViews

// MARK: - Item

struct BSAppItem: Identifiable, Hashable {
	/// The stored source, so a row can name it and tint from it without a second
	/// lookup per row.
	let storedSource: AltSource
	let sourceURL: URL?
	let source: ASRepository
	let app: ASRepository.App

	var id: String {
		"\(sourceURL?.absoluteString ?? "")|\(app.currentUniqueId)"
	}

	static func == (lhs: BSAppItem, rhs: BSAppItem) -> Bool { lhs.id == rhs.id }

	func hash(into hasher: inout Hasher) { hasher.combine(id) }

	/// What sits under the name: the source's own category when it has one,
	/// the developer when it doesn't, and the source's name as a last resort.
	var subtitle: String {
		if let category = app.category?.trimmingCharacters(in: .whitespacesAndNewlines), !category.isEmpty {
			return category
		}
		if let developer = app.developer?.trimmingCharacters(in: .whitespacesAndNewlines), !developer.isEmpty {
			return developer
		}
		return source.name ?? sourceURL?.host ?? "App"
	}
}

// MARK: - Index

enum BSAppIndex {
	// MARK: Cache

	private static let _lock = NSLock()
	private static var _cachedKey = ""
	private static var _cachedItems: [BSAppItem] = []

	/// The catalogue is the same list for the Apps tab and the search tab, so it
	/// is built once and handed to both rather than twice in parallel.
	static func cached(for key: String) -> [BSAppItem]? {
		_lock.lock()
		defer { _lock.unlock() }
		return _cachedKey == key ? _cachedItems : nil
	}

	static func cache(_ items: [BSAppItem], for key: String) {
		_lock.lock()
		_cachedKey = key
		_cachedItems = items
		_lock.unlock()
	}

	// MARK: Build

	/// Flattens every loaded source into searchable app rows.
	///
	/// Historical builds from the *same source* are collapsed, but entries are
	/// no longer collapsed globally just because two repositories use the same
	/// bundle id. That old behaviour silently hid variants from search. Apps
	/// without a bundle id are also kept instead of being discarded entirely.
	static func build(sources: [AltSource], repositories: [AltSource: ASRepository]) -> [BSAppItem] {
		var newest: [String: BSAppItem] = [:]
		newest.reserveCapacity(1024)

		for source in sources {
			guard let repository = repositories[source] else { continue }

			let sourceKey = source.sourceURL?.absoluteString
				?? source.identifier
				?? repository.id
				?? repository.name
				?? "source"

			for app in repository.apps {
				let item = BSAppItem(
					storedSource: source,
					sourceURL: source.sourceURL,
					source: repository,
					app: app
				)

				let nameKey = _normalized(app.currentName)
				let developerKey = _normalized(app.developer ?? "")
				let bundle = app.id?.trimmingCharacters(in: .whitespacesAndNewlines)

				let identity: String
				if let bundle, !bundle.isEmpty {
					// Name is part of the identity on purpose. Repositories often
					// publish patched/alternate variants under the same bundle id.
					identity = "id:\(bundle.lowercased())|name:\(nameKey)"
				} else if !nameKey.isEmpty, nameKey != "unknown" {
					identity = "name:\(nameKey)|developer:\(developerKey)"
				} else if let url = app.currentDownloadUrl {
					identity = "url:\(url.absoluteString)"
				} else {
					identity = "entry:\(app.currentUniqueId)"
				}

				let key = "\(sourceKey)|\(identity)"
				guard let existing = newest[key] else {
					newest[key] = item
					continue
				}

				let heldDate = existing.app.currentDate?.date ?? .distantPast
				let candidateDate = app.currentDate?.date ?? .distantPast

				if candidateDate > heldDate {
					newest[key] = item
					continue
				}

				if candidateDate == heldDate {
					let heldVersion = existing.app.currentVersion ?? ""
					let candidateVersion = app.currentVersion ?? ""
					if candidateVersion.compare(heldVersion, options: .numeric) == .orderedDescending {
						newest[key] = item
					}
				}
			}
		}

		return newest.values.sorted {
			$0.app.currentName.localizedCaseInsensitiveCompare($1.app.currentName) == .orderedAscending
		}
	}

	// MARK: Search

	/// Relevance-ranked search across the complete flattened index.
	///
	/// A name match always outranks metadata, exact/prefix matches outrank a
	/// middle-of-word match, and multi-word queries may match across fields. The
	/// old boolean `contains` filter made a category/developer containing "gt"
	/// compete equally with an app actually named "GTA", which produced noisy
	/// results and made the intended app look missing.
	static func filter(_ items: [BSAppItem], query: String, limit: Int = 200) -> [BSAppItem] {
		let wanted = _normalized(query)
		guard !wanted.isEmpty, limit > 0 else { return [] }

		let tokens = wanted.split(separator: " ").map(String.init)
		var matches: [(score: Int, item: BSAppItem)] = []
		matches.reserveCapacity(min(items.count, limit))

		for item in items {
			let name = _normalized(item.app.currentName)
			let bundle = _normalized(item.app.id ?? "")
			let developer = _normalized(item.app.developer ?? "")
			let category = _normalized(item.app.category ?? "")
			let subtitle = _normalized(item.app.subtitle ?? "")
			let localizedDescription = _normalized(item.app.localizedDescription ?? "")
			let description = _normalized(item.app.description ?? "")
			let source = _normalized(item.source.name ?? item.storedSource.name ?? "")

			let fields = [name, bundle, developer, category, subtitle, localizedDescription, description, source]
			guard tokens.allSatisfy({ token in fields.contains(where: { $0.contains(token) }) }) else {
				continue
			}

			var score = 0

			if name == wanted {
				score += 100_000
			} else if name.hasPrefix(wanted) {
				score += 90_000
			} else if _wordStarts(name, with: wanted) {
				score += 85_000
			} else if name.contains(wanted) {
				score += 80_000
			}

			if bundle == wanted { score += 70_000 }
			else if bundle.hasPrefix(wanted) { score += 55_000 }
			else if bundle.contains(wanted) { score += 45_000 }

			if developer == wanted { score += 35_000 }
			else if developer.hasPrefix(wanted) { score += 30_000 }
			else if developer.contains(wanted) { score += 25_000 }

			if category == wanted { score += 18_000 }
			else if category.contains(wanted) { score += 12_000 }

			if subtitle.contains(wanted) { score += 10_000 }
			if source.contains(wanted) { score += 8_000 }
			if localizedDescription.contains(wanted) { score += 5_000 }
			if description.contains(wanted) { score += 4_000 }

			// Reward every name token independently so "gta san" naturally
			// floats GTA/San-Andreas-like names above metadata-only matches.
			for token in tokens {
				if name.hasPrefix(token) { score += 2_000 }
				else if _wordStarts(name, with: token) { score += 1_700 }
				else if name.contains(token) { score += 1_300 }
				else if bundle.contains(token) { score += 700 }
				else if developer.contains(token) { score += 350 }
				else if category.contains(token) { score += 180 }
				else { score += 50 }
			}

			matches.append((score, item))
		}

		matches.sort { lhs, rhs in
			if lhs.score != rhs.score { return lhs.score > rhs.score }
			let nameOrder = lhs.item.app.currentName.localizedCaseInsensitiveCompare(rhs.item.app.currentName)
			if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
			return lhs.item.id < rhs.item.id
		}

		return Array(matches.prefix(limit).map(\.item))
	}

	private static func _wordStarts(_ text: String, with query: String) -> Bool {
		text.split(separator: " ").contains { $0.hasPrefix(query) }
	}

	/// Case/diacritic/width-insensitive text with punctuation reduced to spaces.
	/// This makes `GTA-III`, `GTA III` and differently-cased source metadata
	/// searchable by the same query, while continuing to work with Arabic text.
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

// MARK: - Row

/// One row of the catalogue. Deliberately the same row the storefront uses,
/// with the same pill: an app has to report the same state wherever it is
/// listed, or the button starts lying on whichever screen the user happens to
/// be looking at.
struct BSAppRow: View {
	let item: BSAppItem
	var showsChevron: Bool = false
	var showsPill: Bool = true

	var body: some View {
		BSStoreRow(
			storedSource: item.storedSource,
			sourceURL: item.sourceURL,
			repository: item.source,
			app: item.app,
			showsSeparator: false,
			showsChevron: showsChevron,
			showsPill: showsPill
		)
	}
}

/// The list itself: rows and their hairlines, nothing else. Used by the Apps tab
/// and by search, so a result and a catalogue row can never drift apart.
struct BSAppList: View {
	let items: [BSAppItem]

	/// When set, rows are *picked* rather than opened.
	///
	/// A source's catalogue is where a multi-sign run usually starts — the apps
	/// are not in the Library yet — and picking them here has to be the same
	/// gesture as picking them there. The GET pill goes away in this mode: the
	/// row answers one question, and the answer is not "download this one".
	var picking: Binding<Set<String>>? = nil

	var body: some View {
		LazyVStack(spacing: 0) {
			ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
				if let picking {
					Button {
						BSHaptics.tap()
						let id = item.id
						withAnimation(.snappy(duration: 0.2)) {
							if picking.wrappedValue.contains(id) {
								picking.wrappedValue.remove(id)
							} else {
								picking.wrappedValue.insert(id)
							}
					} label: {
						_pickingRow(item, picked: picking.wrappedValue.contains(item.id))
					}
					.buttonStyle(.plain)
				} else {
					HStack(spacing: 0) {
						NavigationLink {
							SourceAppsDetailView(
								sourceURL: item.sourceURL,
								source: item.source,
								app: item.app
							)
						} label: {
							BSStoreRow(
								storedSource: item.storedSource,
								sourceURL: item.sourceURL,
								repository: item.source,
								app: item.app,
								showsSeparator: false,
								showsChevron: false,
								showsPill: false
							)
						}
						.buttonStyle(.plain)
						.frame(maxWidth: .infinity)

						BSGetPill(sourceURL: item.sourceURL, repository: item.source, app: item.app)
							.padding(.trailing, 16)
					}
				}

				if index < items.count - 1 {
					// Inset to the row's own leading edge, the way the App Store
					// runs its separators under the icon rather than past it.
					Rectangle()
						.fill(BSStore.separator)
						.frame(height: 0.5)
						.padding(.leading, 16)
				}
			}
		}
	}

	/// One row, while apps are being picked: the tick in the leading gutter the
	/// system uses for this, then the row itself with its pill switched off.
	private func _pickingRow(_ item: BSAppItem, picked: Bool) -> some View {
		HStack(spacing: 4) {
			Image(systemName: picked ? "checkmark.circle.fill" : "circle")
				.font(.system(size: 22, weight: .regular))
				.foregroundStyle(picked ? BS.accent : Color.secondary.opacity(0.45))
				.padding(.leading, 12)
				.padding(.trailing, 4)

			BSAppRow(item: item, showsPill: false)
		}
		.contentShape(Rectangle())
	}
}
