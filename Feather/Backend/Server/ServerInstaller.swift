//
//  Server.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import Network
import Vapor
import NIOSSL
import NIOTLS
import SwiftUI
import IDeviceSwift

// MARK: - Class
class ServerInstaller: Identifiable, ObservableObject {
	let id = UUID()
	// GBox 6.1.3 starts its local HTTP server on 9800 before opening
	// https://i.gbox.run/install.plist. Keep the same fixed port.
	let port = 9800
	private var _needsShutdown = false

	var packageUrl: URL? {
		didSet { _gboxServer?.packageURL = packageUrl }
	}
	var app: AppInfoPresentable
	@ObservedObject var viewModel: InstallerStatusViewModel
	private var _server: Application?
	private var _gboxServer: GBoxLoopbackServer?

	private(set) var startupError: Error?
	var usesTLS = false

	init(app: AppInfoPresentable, viewModel: InstallerStatusViewModel) {
		self.app = app
		self.viewModel = viewModel

		if getServerMethod() == 0 {
			do {
				let server = try GBoxLoopbackServer(port: UInt16(port))
				server.onServing = { [weak self] in
					self?._updateStatus(.sendingPayload)
				}
				server.onFullTransfer = { [weak self] in
					self?._updateStatus(.installing)
					DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
						self?.stop()
					}
				}
				server.onError = { [weak self] error in
					self?._updateStatus(.broken(error))
				}
				_gboxServer = server
			} catch {
				startupError = error
			}
			return
		}

		_setup()
		_configureRoutes()

		do {
			try _server?.server.start()
			_needsShutdown = _server != nil
		} catch {
			startupError = error
			_server = nil
		}
	}

	var isAvailable: Bool {
		if getServerMethod() == 0 {
			return _gboxServer != nil && startupError == nil
		}
		return _server != nil
	}

	func stop() {
		_gboxServer?.stop()
		_gboxServer = nil
		_shutdownServer()
		_server = nil
		packageUrl = nil
	}

	deinit {
		_gboxServer?.stop()
		_shutdownServer()
	}

	private func _setup() {
		do {
			_server = try setupApp(port: port)
		} catch {
			startupError = error
			_server = nil
		}
	}

	private func _configureRoutes() {
		_server?.get("*") { [weak self] req in
			guard let self else { return Response(status: .badGateway) }
			switch req.url.path {
			case plistEndpoint.path:
				self._updateStatus(.sendingManifest)
				return Response(
					status: .ok,
					version: req.version,
					headers: ["Content-Type": "text/xml"],
					body: .init(data: installManifestData)
				)
			case displayImageSmallEndpoint.path:
				return Response(
					status: .ok,
					version: req.version,
					headers: ["Content-Type": "image/png"],
					body: .init(data: displayImageSmallData)
				)
			case displayImageLargeEndpoint.path:
				return Response(
					status: .ok,
					version: req.version,
					headers: ["Content-Type": "image/png"],
					body: .init(data: displayImageLargeData)
				)
			case payloadEndpoint.path, gboxPayloadEndpoint.path:
				guard let packageUrl else { return Response(status: .notFound) }
				self._updateStatus(.sendingPayload)
				return req.fileio.streamFile(at: packageUrl.path) { result in
					switch result {
					case .success:
						self._updateStatus(.installing)
					case .failure(let error):
						self._updateStatus(.broken(error))
					}
				}
			case "/install":
				var headers = HTTPHeaders()
				headers.add(name: .contentType, value: "text/html")
				return Response(status: .ok, headers: headers, body: .init(string: html))
			default:
				return Response(status: .notFound)
			}
		}
	}

	private func _shutdownServer() {
		guard _needsShutdown else { return }
		_needsShutdown = false
		_server?.server.shutdown()
		_server?.shutdown()
	}

	private func _updateStatus(_ newStatus: InstallerStatusViewModel.InstallerStatus) {
		DispatchQueue.main.async {
			self.viewModel.status = newStatus
		}
	}

	func getServerMethod() -> Int {
		UserDefaults.standard.integer(forKey: "Feather.serverMethod")
	}

	func getIPFix() -> Bool {
		UserDefaults.standard.bool(forKey: "Feather.ipFix")
	}
}

// MARK: - GBox loopback payload server
// GBox 6.1.3 serves .InstallPackage/app.ipa from its local HTTP server on
// port 9800. Keep the same loopback route used by the GBox production
// install.plist: http://127.0.0.1:9800/app.ipa.
private final class GBoxLoopbackServer {
	private let listener: NWListener
	private let queue = DispatchQueue(label: "app.batsign.gbox-loopback", qos: .userInitiated)
	private let packageLock = NSLock()
	private var _packageURL: URL?
	private var stopped = false

	var packageURL: URL? {
		get {
			packageLock.lock()
			defer { packageLock.unlock() }
			return _packageURL
		}
		set {
			packageLock.lock()
			_packageURL = newValue
			packageLock.unlock()
		}
	}

	var onServing: (() -> Void)?
	var onFullTransfer: (() -> Void)?
	var onError: ((Error) -> Void)?

	init(port: UInt16) throws {
		guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
			throw NSError(
				domain: "BatSign.GBoxLoopback",
				code: 1,
				userInfo: [NSLocalizedDescriptionKey: "Invalid GBox loopback port."]
			)
		}
		guard let loopback = IPv4Address("127.0.0.1") else {
			throw NSError(
				domain: "BatSign.GBoxLoopback",
				code: 3,
				userInfo: [NSLocalizedDescriptionKey: "Invalid loopback address."]
			)
		}

		let parameters = NWParameters.tcp
		parameters.allowLocalEndpointReuse = true
		parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(loopback), port: endpointPort)

		// The port is already fixed by requiredLocalEndpoint. Passing the same
		// port again through NWListener(using:on:) produces EINVAL on iOS.
		listener = try NWListener(using: parameters)

		listener.newConnectionHandler = { [weak self] connection in
			self?._accept(connection)
		}
		listener.stateUpdateHandler = { [weak self] state in
			guard let self else { return }
			if case .failed(let error) = state {
				self.onError?(error)
			}
		}
		listener.start(queue: queue)
	}

	func stop() {
		guard !stopped else { return }
		stopped = true
		listener.cancel()
	}

	private func _accept(_ connection: NWConnection) {
		connection.start(queue: queue)
		_readRequest(connection, buffer: Data())
	}

	private func _readRequest(_ connection: NWConnection, buffer: Data) {
		connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
			guard let self else {
				connection.cancel()
				return
			}
			if let error {
				self.onError?(error)
				connection.cancel()
				return
			}

			var next = buffer
			if let data { next.append(data) }
			if next.count > 65_536 {
				self._sendSimple(connection, status: "431 Request Header Fields Too Large")
				return
			}
			if next.range(of: Data("\r\n\r\n".utf8)) != nil {
				self._handleRequest(next, on: connection)
				return
			}
			if isComplete {
				connection.cancel()
				return
			}
			self._readRequest(connection, buffer: next)
		}
	}

	private func _handleRequest(_ data: Data, on connection: NWConnection) {
		guard let request = String(data: data, encoding: .utf8) else {
			_sendSimple(connection, status: "400 Bad Request")
			return
		}

		let firstLine = request.components(separatedBy: "\r\n").first ?? ""
		let parts = firstLine.split(separator: " ")
		guard parts.count >= 2 else {
			_sendSimple(connection, status: "400 Bad Request")
			return
		}

		let method = String(parts[0]).uppercased()
		let path = String(parts[1])
		guard (method == "GET" || method == "HEAD"), path == "/app.ipa" else {
			_sendSimple(connection, status: "404 Not Found")
			return
		}

		guard let url = packageURL else {
			_sendSimple(connection, status: "503 Service Unavailable")
			return
		}

		do {
			let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
			guard let sizeNumber = attrs[.size] as? NSNumber else {
				_sendSimple(connection, status: "500 Internal Server Error")
				return
			}
			let total = sizeNumber.uint64Value
			guard total > 0 else {
				_sendSimple(connection, status: "404 Not Found")
				return
			}

			let requestedRange = _range(from: request, total: total)
			let start = requestedRange?.lowerBound ?? 0
			let end = requestedRange?.upperBound ?? (total - 1)
			guard start <= end, end < total else {
				_sendSimple(
					connection,
					status: "416 Range Not Satisfiable",
					extraHeaders: ["Content-Range": "bytes */\(total)"]
				)
				return
			}

			let length = end - start + 1
			var headers: [String: String] = [
				"Content-Type": "application/octet-stream",
				"Content-Length": "\(length)",
				"Accept-Ranges": "bytes",
				"Cache-Control": "no-store",
				"Connection": "close",
			]
			let status: String
			if requestedRange != nil {
				status = "206 Partial Content"
				headers["Content-Range"] = "bytes \(start)-\(end)/\(total)"
			} else {
				status = "200 OK"
			}

			_onServingMain()
			let headerData = Data(_header(status: status, headers: headers).utf8)
			connection.send(content: headerData, completion: .contentProcessed { [weak self] error in
				guard let self else {
					connection.cancel()
					return
				}
				if let error {
					self.onError?(error)
					connection.cancel()
					return
				}
				if method == "HEAD" {
					connection.cancel()
					return
				}
				self._streamFile(
					url: url,
					start: start,
					length: length,
					isWholeFile: start == 0 && end == total - 1,
					to: connection
				)
			})
		} catch {
			onError?(error)
			_sendSimple(connection, status: "500 Internal Server Error")
		}
	}

	private func _streamFile(
		url: URL,
		start: UInt64,
		length: UInt64,
		isWholeFile: Bool,
		to connection: NWConnection
	) {
		guard let handle = try? FileHandle(forReadingFrom: url) else {
			_sendSimple(connection, status: "500 Internal Server Error")
			return
		}
		handle.seek(toFileOffset: start)

		final class StreamState {
			let handle: FileHandle
			var remaining: UInt64
			init(handle: FileHandle, remaining: UInt64) {
				self.handle = handle
				self.remaining = remaining
			}
		}

		let state = StreamState(handle: handle, remaining: length)
		let chunkSize: UInt64 = 512 * 1024

		func pump() {
			if state.remaining == 0 {
				state.handle.closeFile()
				connection.cancel()
				if isWholeFile { self._onFullTransferMain() }
				return
			}

			let count = Int(min(chunkSize, state.remaining))
			let chunk = state.handle.readData(ofLength: count)
			if chunk.isEmpty {
				state.handle.closeFile()
				let error = NSError(
					domain: "BatSign.GBoxLoopback",
					code: 2,
					userInfo: [NSLocalizedDescriptionKey: "The local IPA stream ended before all bytes were sent."]
				)
				self.onError?(error)
				connection.cancel()
				return
			}

			state.remaining -= UInt64(chunk.count)
			connection.send(content: chunk, completion: .contentProcessed { error in
				if let error {
					state.handle.closeFile()
					self.onError?(error)
					connection.cancel()
					return
				}
				pump()
			})
		}

		pump()
	}

	private func _range(from request: String, total: UInt64) -> ClosedRange<UInt64>? {
		guard total > 0 else { return nil }
		guard let line = request.components(separatedBy: "\r\n").first(where: {
			$0.lowercased().hasPrefix("range:")
		}) else { return nil }

		guard let colon = line.firstIndex(of: ":") else { return nil }
		let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
		guard raw.lowercased().hasPrefix("bytes=") else { return nil }
		let spec = String(raw.dropFirst(6)).split(separator: ",").first.map(String.init) ?? ""
		let sides = spec.split(separator: "-", omittingEmptySubsequences: false)
		guard sides.count == 2 else { return nil }

		let left = String(sides[0])
		let right = String(sides[1])
		if left.isEmpty {
			guard let suffix = UInt64(right), suffix > 0 else { return nil }
			let count = min(suffix, total)
			return (total - count)...(total - 1)
		}

		guard let start = UInt64(left), start < total else { return nil }
		let end: UInt64
		if right.isEmpty {
			end = total - 1
		} else if let parsed = UInt64(right) {
			end = min(parsed, total - 1)
		} else {
			return nil
		}
		guard start <= end else { return nil }
		return start...end
	}

	private func _sendSimple(
		_ connection: NWConnection,
		status: String,
		extraHeaders: [String: String] = [:]
	) {
		var headers = extraHeaders
		headers["Content-Length"] = "0"
		headers["Connection"] = "close"
		let data = Data(_header(status: status, headers: headers).utf8)
		connection.send(content: data, completion: .contentProcessed { _ in
			connection.cancel()
		})
	}

	private func _header(status: String, headers: [String: String]) -> String {
		var result = "HTTP/1.1 \(status)\r\n"
		for (key, value) in headers {
			result += "\(key): \(value)\r\n"
		}
		result += "\r\n"
		return result
	}

	private func _onServingMain() {
		DispatchQueue.main.async { [weak self] in self?.onServing?() }
	}

	private func _onFullTransferMain() {
		DispatchQueue.main.async { [weak self] in self?.onFullTransfer?() }
	}
}
