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

	/// A one-time, atomic repair of bundled sources on existing installations.
	///
	/// Old releases silently inserted \`/refs/heads/main/ipastrong.json\` on
	/// every launch. Changing that URL in another migration only created a
	/// second row, while the old bootstrap inserted the first one again.
	/// The owner requested a clean reset: retain iKiraPlus, remove ALL other
	/// old catalogue rows once, and create exactly one new IPA Strong entry.
	/// Signing certificates, imported IPAs, and the app Library are untouched.
	func installCleanCatalogSources() {
		let mainURL = URL(string: "https://ikiraplus.pages.dev/IPA-AR.json")!
		let strongURL = URL(string:
			"https://raw.githubusercontent.com/sgad73055-code/ipastrong/main/ipastrong.json")!
		let migrationKey = "BatSign.didCleanReinstallIPAstrong250V1"
		let needsReset = !UserDefaults.standard.bool(forKey: migrationKey)

		let request: NSFetchRequest<AltSource> = AltSource.fetchRequest()
		let all: [AltSource]
		do {
			all = try context.fetch(request)
		} catch {
			Logger.misc.error("Unable to inspect sources during repair: \(error)")
			return
		}

		var staleURLs = Set<URL>()
		var keptMain = false
		var keptStrong = false
		for source in all {
			let url = source.sourceURL
			if url == mainURL {
				if keptMain {
					context.delete(source)
				} else {
					keptMain = true
				}
				continue
			}

			if url == strongURL, !needsReset, !keptStrong {
				keptStrong = true
				source.name = "IPA Strong"
				source.identifier = strongURL.absoluteString
				continue
			}

			let name = (source.name ?? "").lowercased()
			let identifier = (source.identifier ?? "").lowercased()
			let urlString = url?.absoluteString.lowercased() ?? ""
			let isLegacyStrong = name.contains("ipastrong")
				|| identifier.contains("ipastrong")
				|| urlString.contains("ipastrong")
				|| urlString.contains("/sgad73055-code/")

			if needsReset || isLegacyStrong || url == strongURL {
				if let url { staleURLs.insert(url) }
				context.delete(source)
			}
		}

		if !keptMain {
			let source = AltSource(context: context)
			source.sourceURL = mainURL
			source.identifier = mainURL.absoluteString
			source.name = "iKiraPlus - IPA Store"
			source.date = Date()
		}

		if !keptStrong {
			let source = AltSource(context: context)
			source.sourceURL = strongURL
			source.identifier = strongURL.absoluteString
			source.name = "IPA Strong"
			source.date = Date()
		}

		if let error = saveContext() {
			Logger.misc.error("Catalogue repair failed; will retry at launch: \(error)")
			return
		}

		// Purge old source feed files only AFTER successful Core Data commit.
		// The primary catalogue's cache is intentionally preserved.
		if needsReset {
			staleURLs.insert(strongURL)
		}
		for url in staleURLs where url != mainURL {
			purgeCachedSource(url)
		}
		if needsReset {
			UserDefaults.standard.set(true, forKey: migrationKey)
		}
	}

	/// The cache key must match BSRepositoryDiskCache.filename(for:).
	/// Delete only removed source caches, never the primary iKiraPlus cache.
	private func purgeCachedSource(_ url: URL) {
		var hash: UInt64 = 14_695_981_039_346_656_037
		for byte in url.absoluteString.utf8 {
			hash ^= UInt64(byte)
			hash &*= 1_099_511_628_211
		}
		guard let root = FileManager.default.urls(
			for: .cachesDirectory, in: .userDomainMask
		).first else { return }
		let file = root.appendingPathComponent(
			"BatSignSourceRepositories", isDirectory: true
		).appendingPathComponent(String(hash, radix: 16) + ".json")
		try? FileManager.default.removeItem(at: file)
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
