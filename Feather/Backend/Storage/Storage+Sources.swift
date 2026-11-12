//
//  Storage+Sources.swift
//  Feather
//
//  Created by samara on 12.04.2025.
//

import CoreData
import AltSourceKit
import OSLog
import UIKit.UIImpactFeedbackGenerator

// MARK: - Class extension: Sources
extension Storage {
	/// Retrieve sources in an array, we don't normally need this in swiftUI but we have it for the copy sources action
	func getSources() -> [AltSource] {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		return (try? context.fetch(request)) ?? []
	}
	
	func addSource(
		_ url: URL,
		name: String? = "Unknown",
		identifier: String,
		iconURL: URL? = nil,
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		// A repository's JSON id is not globally unique. Two independent
		// catalogue URLs can advertise the same id; only the URL determines
		// whether the user already added this particular source.
		if sourceExists(url: url) {
			completion(nil)
			Logger.misc.debug("source URL already saved: \(url.absoluteString)")
			return
		}
		let uniqueIdentifier = sourceExists(identifier)
			? url.absoluteString
			: identifier
		
		let generator = UIImpactFeedbackGenerator(style: .light)
		
		let new = AltSource(context: context)
		new.name = name
		new.date = Date()
		new.identifier = uniqueIdentifier
		new.sourceURL = url
		new.iconURL = iconURL
		
		do {
			if !deferSave {
				try context.save()
				generator.impactOccurred()
			}
			completion(nil)
		} catch {
			context.delete(new)
			completion(error)
		}
	}
	
	func addSource(
		_ url: URL,
		repository: ASRepository,
		id: String = "",
		deferSave: Bool = false,
		completion: @escaping (Error?) -> Void
	) {
		addSource(
			url,
			name: repository.name,
			identifier: !id.isEmpty
				? id
				: (repository.id ?? url.absoluteString),
			iconURL: repository.currentIconURL,
			deferSave: deferSave,
			completion: completion
		)
	}

	func addSources(
		repos: [URL: ASRepository],
		completion: @escaping (Error?) -> Void
	) {
		let generator = UIImpactFeedbackGenerator(style: .light)
		var addedSources: [AltSource] = []
		var seenIdentifiers = Set<String>()
		
		for (url, repo) in repos {
			guard !sourceExists(url: url) else { continue }
			let requestedID = repo.id ?? url.absoluteString
			let identifier = (seenIdentifiers.contains(requestedID) || sourceExists(requestedID))
				? url.absoluteString : requestedID
			guard seenIdentifiers.insert(identifier).inserted else { continue }
			let source = AltSource(context: context)
			source.name = repo.name
			source.date = Date()
			source.identifier = identifier
			source.sourceURL = url
			source.iconURL = repo.currentIconURL
			addedSources.append(source)
		}
		
		if let error = saveContext() {
			addedSources.forEach(context.delete)
			completion(error)
			return
		}
		generator.impactOccurred()
		completion(nil)
	}

	/// Normalise the already-added IPA Strong catalogue to its official
	/// canonical GitHub RAW URL, without adding extra sources or touching the
	/// primary iKiraPlus source. Keep the existing Core Data object so source
	/// preferences and update settings survive.
	/// Keep exactly one IPA Strong entry, with exactly the owner's canonical
	/// URL. Earlier builds used alternate URLs/identifiers and could leave an
	/// extra hostname-only row when the canonical entry was already present.
	/// Never modify or remove the iKiraPlus catalogue or unrelated sources.
	func normaliseIPAstrongSourceURL() {
		guard let canonical = URL(string:
			"https://raw.githubusercontent.com/sgad73055-code/ipastrong/main/ipastrong.json"
		) else { return }

		let matching = getSources().filter { source in
			let name = (source.name ?? "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.lowercased()
			let path = (source.sourceURL?.path ?? "").lowercased()
			let id = (source.identifier ?? "").lowercased()
			return source.sourceURL == canonical
				|| path.contains("/sgad73055-code/ipastrong/")
				|| name == "ipastrong"
				|| id == "ipastrong"
		}
		guard !matching.isEmpty else { return }

		// Prefer the already-canonical row so its settings, identifier and
		// underlying Core Data identity remain stable across upgrades.
		let keeper = matching.first(where: { $0.sourceURL == canonical }) ?? matching[0]
		for duplicate in matching where duplicate.objectID != keeper.objectID {
			context.delete(duplicate)
		}

		keeper.sourceURL = canonical
		keeper.name = "ipastrong"
		// The original JSON identifier can overlap with a different source.
		let otherIDs = Set(getSources().filter {
			$0.objectID != keeper.objectID && !$0.isDeleted
		}.compactMap(\.identifier))
		if let identifier = keeper.identifier, otherIDs.contains(identifier) {
			keeper.identifier = canonical.absoluteString
		}
		_ = saveContext()
	}

	func deleteSource(for source: AltSource) {
		context.delete(source)
		saveContext()
	}

	func sourceExists(url: URL) -> Bool {
		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		request.predicate = NSPredicate(format: "sourceURL == %@", url as NSURL)
		do {
			return try context.count(for: request) > 0
		} catch {
			Logger.misc.error("Error checking source URL: \(error)")
			return false
		}
	}

	func sourceExists(_ identifier: String) -> Bool {
		let fetchRequest: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		fetchRequest.predicate = NSPredicate(format: "identifier == %@", identifier)

		do {
			let count = try context.count(for: fetchRequest)
			return count > 0
		} catch {
			Logger.misc.error("Error checking if repository exists: \(error)")
			return false
		}
	}
}
