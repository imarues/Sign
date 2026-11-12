//
//  SourceInstallIntent.swift
//  Feather
//
//  Explicit install choices started from a source's GET button.
//

import CoreData
import Foundation

@MainActor
enum SourceInstallIntent {
	private static let directPrefix = "BatSignDirect_"
	private static let duplicatePrefix = "BatSignDuplicate_"

	/// Handles an explicit source install request after the downloaded IPA has
	/// been imported into the Library. Returning true means this transfer had an
	/// explicit intent and the ordinary auto-sign/collect routing must not run.
	static func handleIfRequested(
		transferID: String?,
		uuid: String,
		name: String,
		cardID: String,
		identifier: String?
	) -> Bool {
		guard let transferID else { return false }
		let duplicate = transferID.hasPrefix(duplicatePrefix)
		guard duplicate || transferID.hasPrefix(directPrefix) else { return false }

		let request: NSFetchRequest<Imported> = Imported.fetchRequest()
		request.predicate = NSPredicate(format: "uuid == %@", uuid)
		guard let imported = (try? Storage.shared.context.fetch(request))?.first else {
			_refuse(name: name, cardID: cardID,
			        message: "The downloaded IPA could not be found for signing.")
			return true
		}
		guard let baseIdentifier = imported.identifier ?? identifier,
		      !baseIdentifier.isEmpty else {
			_refuse(name: name, cardID: cardID,
			        message: "The downloaded IPA has no valid bundle identifier.")
			return true
		}

		// Ksign's direct/duplicate choices do not inherit a bundle override
		// or a custom display version from a previous manual signing session.
		// The source owns this choice, and signing then installs automatically.
		var options = OptionsManager.shared.options
		options.appName = nil
		options.appVersion = nil
		options.signingOption = .default
		options.post_installAppAfterSigned = true
		if duplicate {
			guard let suffix = _duplicateSuffix(from: transferID) else {
				_refuse(name: name, cardID: cardID,
				        message: "Could not generate a duplicate bundle identifier.")
				return true
			}
			options.appIdentifier = baseIdentifier + suffix
		} else {
			options.appIdentifier = nil
		}

		let queued = AutoSignManager.shared.enqueue(
			app: imported,
			reason: .autoSign,
			options: options,
			force: true
		)
		if !queued {
			_refuse(name: name, cardID: cardID,
			        message: "The app was imported but couldn't be queued for signing.")
		}
		return true
	}

	/// `BatSignDuplicate_ab_<source id>` -> `ab`.
	private static func _duplicateSuffix(from transferID: String) -> String? {
		let remainder = transferID.dropFirst(duplicatePrefix.count)
		guard let separator = remainder.firstIndex(of: "_") else { return nil }
		let suffix = String(remainder[..<separator]).lowercased()
		guard suffix.count == 2 else { return nil }
		let allowed = CharacterSet.alphanumerics
		guard suffix.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
		return suffix
	}

	private static func _refuse(name: String, cardID: String, message: String) {
		LiveStatus.finish(success: false, appName: name, detail: message, appID: cardID)
		AutoSignManager.shared.announceDownloadRefused(
			name: name,
			identifier: cardID,
			message: message
		)
	}
}
