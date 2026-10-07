//
//  IPAHandler.swift
//  Feather
//
//  Created by samara on 11.04.2025.
//

import Foundation
import OSLog
import Zip
import SwiftUI

final class AppFileHandler: NSObject, @unchecked Sendable {
	private let _fileManager = FileManager.default
	private let _uuid = UUID().uuidString
	private let _uniqueWorkDir: URL
	var uniqueWorkDirPayload: URL?

	private var _ipa: URL
	private let _install: Bool
	private let _download: Download?
	private let _sourceProvenance: SourceAppProvenance?
	private let _transferID: String?

	init(
		file ipa: URL,
		install: Bool = false,
		download: Download? = nil,
		sourceProvenance: SourceAppProvenance? = nil,
		transferID: String? = nil
	) {
		self._ipa = ipa
		self._install = install
		self._download = download
		self._sourceProvenance = sourceProvenance ?? download?.sourceProvenance
		self._transferID = transferID ?? download?.id
		self._uniqueWorkDir = _fileManager.temporaryDirectory
			.appendingPathComponent("FeatherImport_\(_uuid)", isDirectory: true)
		super.init()
	}

	func copy() async throws {
		try _fileManager.createDirectoryIfNeeded(at: _uniqueWorkDir)
		let destinationURL = _uniqueWorkDir.appendingPathComponent(_ipa.lastPathComponent)
		try _fileManager.removeFileIfNeeded(at: destinationURL)
		try _fileManager.copyItem(at: _ipa, to: destinationURL)
		_ipa = destinationURL
	}

	func extract() async throws {
		if _ipa.pathExtension == "ipa" { Zip.addCustomFileExtension("ipa") }
		if _ipa.pathExtension == "tipa" { Zip.addCustomFileExtension("tipa") }

		let download = self._download
		try await withCheckedThrowingContinuation { continuation in
			DispatchQueue.global(qos: .userInitiated).async {
				do {
					try Self._rejectUnsafeArchiveEntries(self._ipa, base: self._uniqueWorkDir)
					try Zip.unzipFile(
						self._ipa,
						destination: self._uniqueWorkDir,
						overwrite: true,
						password: nil,
						progress: { progress in
							if let download {
								DispatchQueue.main.async {
									download.unpackageProgress = progress
									DownloadManager.shared.progressDidMove()
								}
							}
						}
					)
					self.uniqueWorkDirPayload = self._uniqueWorkDir.appendingPathComponent("Payload")
					continuation.resume()
				} catch let error as ImportedFileHandlerError {
					continuation.resume(throwing: error)
				} catch {
					continuation.resume(throwing: ImportedFileHandlerError.unreadablePackage(self._ipa.lastPathComponent))
				}
			}
		}
	}

	func move() async throws {
		guard let payloadURL = uniqueWorkDirPayload else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		let destinationURL = try await _directory()
		guard _fileManager.fileExists(atPath: payloadURL.path) else {
			throw ImportedFileHandlerError.payloadNotFound
		}
		try _fileManager.moveItem(at: payloadURL, to: destinationURL)
		try? _fileManager.removeItem(at: _uniqueWorkDir)
	}

	func addToDatabase() async throws {
		let app = try await _directory()
		guard let appUrl = _fileManager.getPath(in: app, for: "app") else {
			try? _fileManager.removeFileIfNeeded(at: app)
			throw ImportedFileHandlerError.appNotFound
		}

		let bundle = Bundle(url: appUrl)
		do {
			try await _awaitImport(bundle: bundle)
		} catch {
			try? _fileManager.removeFileIfNeeded(at: app)
			throw error
		}

		if let transferID = _transferID {
			BSJobJournal.shared.clearIf(transferID: transferID)
		}

		if let sourceProvenance = _sourceProvenance {
			Storage.shared.addSourceMetadata(
				for: _uuid,
				kind: .imported,
				provenance: sourceProvenance
			)
		}

		if let download = _download, let identifier = bundle?.bundleIdentifier {
			await MainActor.run {
				LiveStatus.addAlias(identifier, for: download.liveID)
			}
		}

		let transferID = _transferID ?? _download?.id
		let isLibraryOnlyImport = transferID?.hasPrefix("BatSignLibraryOnly_") ?? false
		let isAutoUpdateDownload = transferID?.hasPrefix(BatSignAuto.downloadPrefix) ?? false
		let isManualUpdateDownload = transferID?.hasPrefix(BatSignAuto.manualUpdatePrefix) ?? false
		let autoIdentifier = bundle?.bundleIdentifier
		let cardName = _download?.cardName ?? bundle?.name ?? "App"
		let cardID = _download?.liveID ?? autoIdentifier ?? _uuid

		await MainActor.run {
			if isLibraryOnlyImport {
				LiveStatus.finish(
					success: true,
					appName: cardName,
					detail: "تمت الإضافة إلى المكتبة",
					appID: cardID
				)
				return
			} else if SourceInstallIntent.handleIfRequested(
				transferID: transferID,
				uuid: _uuid,
				name: cardName,
				cardID: cardID,
				identifier: autoIdentifier
			) {
				return
			} else if isManualUpdateDownload {
				_collectOrEnqueue(
					uuid: _uuid,
					reason: .autoUpdate,
					name: cardName,
					id: cardID,
					identifier: autoIdentifier
				)
			} else if isAutoUpdateDownload {
				guard
					let identifier = autoIdentifier,
					AutoUpdateManager.shared.isAutoUpdateEnabled(for: identifier)
				else {
					_autoSignRefused(
						name: cardName,
						id: cardID,
						reason: "Automatic signing is off for this app."
					)
					return
				}
				_enqueueOrFail(uuid: _uuid, reason: .autoUpdate, name: cardName, id: cardID)
			} else {
				_collectOrEnqueue(
					uuid: _uuid,
					reason: .autoSign,
					name: cardName,
					id: cardID,
					identifier: autoIdentifier
				)
			}
		}
	}

	@MainActor
	private func _collectOrEnqueue(
		uuid: String,
		reason: AutoSignManager.Reason,
		name: String,
		id: String,
		identifier: String?
	) {
		guard !BSBulkSign.shared.isWaiting(for: id) else {
			_enqueueOrFail(uuid: uuid, reason: reason, name: name, id: id)
			return
		}

		if BSPendingSign.shared.collect(uuid: uuid, name: name, identifier: identifier) {
			if let transferID = _download?.id {
				BSJobJournal.shared.clearIf(transferID: transferID)
			}
			LiveStatus.finish(
				success: true,
				appName: name,
				detail: "Waiting for you to sign",
				appID: id
			)
			return
		}

		_enqueueOrFail(uuid: uuid, reason: reason, name: name, id: id)
	}

	@MainActor
	private func _enqueueOrFail(uuid: String, reason: AutoSignManager.Reason, name: String, id: String) {
		if let claim = BSBulkSign.shared.claim(transferID: id) {
			let queued = AutoSignManager.shared.enqueueImported(
				uuid: uuid,
				reason: reason,
				batch: claim.batch,
				force: true
			)
			if !queued {
				BSBulkSign.shared.markFailed(claim.itemID, reason: "It could not be queued for signing")
			}
			return
		}

		if AutoSignManager.shared.enqueueImported(uuid: uuid, reason: reason) { return }

		let detail: String
		if AutoSignManager.shared.isAutoSignEnabled {
			detail = "The app was imported but could not be queued for signing. Open BatSign and sign it from your Library."
		} else {
			detail = "Automatic signing is turned off. Sign \(name) from your Library to install it."
		}
		_autoSignRefused(name: name, id: id, reason: detail)
	}

	@MainActor
	private func _autoSignRefused(name: String, id: String, reason: String) {
		LiveStatus.finish(success: false, appName: name, detail: reason, appID: id)
		AutoSignManager.shared.announceDownloadRefused(name: name, identifier: id, message: reason)
		if let transferID = _download?.id {
			BSJobJournal.shared.clearIf(transferID: transferID)
		}
	}

	private func _awaitImport(bundle: Bundle?) async throws {
		try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
			Storage.shared.addImported(
				uuid: _uuid,
				source: _sourceProvenance?.sourceRepositoryURL,
				appName: bundle?.name,
				appIdentifier: bundle?.bundleIdentifier,
				appVersion: bundle?.version,
				appIcon: bundle?.iconFileName
			) { error in
				if let error {
					continuation.resume(throwing: error)
				} else {
					continuation.resume()
				}
			}
		}
	}

	private func _directory() async throws -> URL {
		_fileManager.unsigned(_uuid)
	}

	func clean() async throws {
		try _fileManager.removeFileIfNeeded(at: _uniqueWorkDir)
	}

	private static func _rejectUnsafeArchiveEntries(_ url: URL, base: URL) throws {
		guard let entryNames = _zipEntryNames(in: url) else {
			Logger.misc.warning("Skipped archive entry validation for \(url.lastPathComponent, privacy: .public)")
			return
		}

		let basePath = base.standardized.path
		for name in entryNames {
			let normalized = name.replacingOccurrences(of: "\\", with: "/")
			let resolved = base.appendingPathComponent(normalized).standardized.path
			guard
				!normalized.hasPrefix("/"),
				resolved == basePath || resolved.hasPrefix(basePath + "/")
			else {
				throw ImportedFileHandlerError.unsafeArchiveEntry(name)
			}
		}
	}

	private static func _zipEntryNames(in url: URL) -> [String]? {
		guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
		defer { try? handle.close() }

		let fileSize = Int64(handle.seekToEndOfFile())
		guard fileSize >= 22 else { return nil }

		let tailLength = Int(min(fileSize, 65557))
		guard let tail = _read(handle, at: fileSize - Int64(tailLength), length: tailLength) else {
			return nil
		}
		guard let eocd = _lastIndex(of: 0x06054b50, in: tail) else { return nil }

		var directoryOffset = UInt64(_uint32(tail, eocd + 16) ?? 0)
		var directoryLength = UInt64(_uint32(tail, eocd + 12) ?? 0)

		if
			eocd >= 20,
			_uint32(tail, eocd - 20) == 0x07064b50,
			let locatorOffset = _uint64(tail, eocd - 12),
			locatorOffset <= UInt64(Int64.max),
			let record = _read(handle, at: Int64(locatorOffset), length: 56),
			_uint32(record, 0) == 0x06064b50
		{
			directoryLength = _uint64(record, 40) ?? directoryLength
			directoryOffset = _uint64(record, 48) ?? directoryOffset
		}

		guard
			directoryLength > 0,
			directoryLength <= 64 * 1024 * 1024,
			directoryOffset <= UInt64(fileSize),
			directoryLength <= UInt64(fileSize) - directoryOffset
		else {
			return nil
		}

		guard let directory = _read(handle, at: Int64(directoryOffset), length: Int(directoryLength)) else {
			return nil
		}
		return _entryNames(in: directory)
	}

	private static func _entryNames(in directory: Data) -> [String]? {
		guard _uint32(directory, 0) == 0x02014b50 else { return nil }
		var names: [String] = []
		var offset = 0

		while offset + 46 <= directory.count {
			guard _uint32(directory, offset) == 0x02014b50 else { break }
			guard
				let nameLength = _uint16(directory, offset + 28),
				let extraLength = _uint16(directory, offset + 30),
				let commentLength = _uint16(directory, offset + 32),
				offset + 46 + nameLength <= directory.count
			else {
				return nil
			}

			let nameData = directory.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
			names.append(
				String(data: nameData, encoding: .utf8)
					?? String(data: nameData, encoding: .isoLatin1)
					?? ""
			)
			offset += 46 + nameLength + extraLength + commentLength
		}
		return names
	}

	private static func _read(_ handle: FileHandle, at offset: Int64, length: Int) -> Data? {
		guard offset >= 0, length > 0 else { return nil }
		do {
			try handle.seek(toOffset: UInt64(offset))
			guard let data = try handle.read(upToCount: length), data.count == length else {
				return nil
			}
			return data
		} catch {
			return nil
		}
	}

	private static func _lastIndex(of signature: UInt32, in data: Data) -> Int? {
		let bytes: [UInt8] = [
			UInt8(signature & 0xff),
			UInt8((signature >> 8) & 0xff),
			UInt8((signature >> 16) & 0xff),
			UInt8((signature >> 24) & 0xff)
		]
		guard data.count >= bytes.count else { return nil }
		for index in stride(from: data.count - bytes.count, through: 0, by: -1) {
			if
				data[index] == bytes[0],
				data[index + 1] == bytes[1],
				data[index + 2] == bytes[2],
				data[index + 3] == bytes[3]
			{
				return index
			}
		}
		return nil
	}

	private static func _uint16(_ data: Data, _ offset: Int) -> Int? {
		guard offset >= 0, offset + 2 <= data.count else { return nil }
		return Int(data[offset]) | (Int(data[offset + 1]) << 8)
	}

	private static func _uint32(_ data: Data, _ offset: Int) -> UInt32? {
		guard offset >= 0, offset + 4 <= data.count else { return nil }
		var value: UInt32 = 0
		for byte in (0..<4).reversed() {
			value = (value << 8) | UInt32(data[offset + byte])
		}
		return value
	}

	private static func _uint64(_ data: Data, _ offset: Int) -> UInt64? {
		guard offset >= 0, offset + 8 <= data.count else { return nil }
		var value: UInt64 = 0
		for byte in (0..<8).reversed() {
			value = (value << 8) | UInt64(data[offset + byte])
		}
		return value
	}
}

private enum ImportedFileHandlerError: Error, LocalizedError {
	case payloadNotFound
	case appNotFound
	case unsafeArchiveEntry(String)
	case unreadablePackage(String)

	var errorDescription: String? {
		switch self {
		case .payloadNotFound:
			"The package has no Payload folder — it is not an app."
		case .appNotFound:
			"The package has no app inside its Payload folder."
		case .unsafeArchiveEntry(let entry):
			"The package tries to write outside its own folder (\(entry)), so it was refused."
		case .unreadablePackage(let name):
			"‘\(name)’ could not be opened — the file is not a valid app package."
		}
	}
}
