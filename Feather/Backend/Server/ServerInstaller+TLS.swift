//
//  Server+TLS.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import NIOSSL
import NIOTLS
import Vapor
import SystemConfiguration.CaptiveNetwork

// MARK: - Class extension: TLS/Setup
extension ServerInstaller {
	/// Kept for compatibility with the existing certificate management code.
	/// GBox OTA installs no longer require this identity for the local payload.
	private static let tlsIdentityLock = NSLock()

	static func withTLSIdentityLock<T>(_ operation: () throws -> T) rethrows -> T {
		tlsIdentityLock.lock()
		defer { tlsIdentityLock.unlock() }
		return try operation()
	}

	static func validateTLSIdentity(
		certificateURL: URL,
		privateKeyURL: URL
	) throws {
		_ = try NIOSSLContext(
			configuration: makeTLSConfiguration(
				certificateURL: certificateURL,
				privateKeyURL: privateKeyURL
			)
		)
	}

	private static func makeTLSConfiguration(
		certificateURL: URL,
		privateKeyURL: URL
	) throws -> TLSConfiguration {
		try TLSConfiguration.makeServerConfiguration(
			certificateChain: NIOSSLCertificate.fromPEMFile(certificateURL.path).map {
				NIOSSLCertificateSource.certificate($0)
			},
			privateKey: .privateKey(
				try NIOSSLPrivateKey(file: privateKeyURL.path, format: .pem)
			)
		)
	}

	static let env: Environment = {
		var env = (try? Environment.detect()) ?? .development
		try? LoggingSystem.bootstrap(from: &env)
		return env
	}()
	
	func setupApp(port: Int) throws -> Application {
		let app = Application(Self.env)
		app.threadPool = .init(numberOfThreads: 1)

		// GBox/NeoSign's reliable OTA path serves the IPA from a plain HTTP
		// loopback listener while the manifest itself is HTTPS on GBox. Do not
		// attach the old Backloop/local TLS identity here: installd will fetch
		// http://127.0.0.1:<port>/app.ipa directly from this process.
		usesTLS = false

		app.http.server.configuration.hostname = sni()
		app.http.server.configuration.tcpNoDelay = true
		app.http.server.configuration.address = .hostname("0.0.0.0", port: port)
		app.http.server.configuration.port = port
		app.routes.defaultMaxBodySize = "128mb"
		app.routes.caseInsensitive = false
		return app
	}

	// MARK: Files/IP
	func sni() -> String {
		let localhost = "127.0.0.1"
		
		// Semi-local/webview mode may still use the device address when requested.
		if getServerMethod() == 1 {
			return !self.getIPFix()
				? (Self.getLocalAddress() ?? localhost)
				: localhost
		}

		// GBox manifest mode must always point back to this phone, independent of
		// any downloaded SSL certificate/common-name file.
		return localhost
	}

	static func hasCertificateMaterial() -> Bool {
		guard
			Self.getUrl("server", ext: "crt") != nil,
			Self.getUrl("server", ext: "pem") != nil,
			let name = Self.getUrl("commonName", ext: "txt"),
			let contents = try? String(contentsOf: name, encoding: .utf8)
		else {
			return false
		}
		return !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
	}

	private static func isUsableTLSHost(_ host: String) -> Bool {
		guard
			!host.isEmpty,
			host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
			let components = URLComponents(string: "https://\(host)"),
			components.host == host,
			components.url != nil
		else {
			return false
		}
		return true
	}
	
	func tls() throws -> TLSConfiguration? {
		guard !FR.isActiveSSLCertificateBlocked() else { return nil }

		return try Self.withTLSIdentityLock {
			guard
				let crt = Self.getUrl("server", ext: "crt"),
				let pem = Self.getUrl("server", ext: "pem")
			else {
				return nil
			}

			return try Self.makeTLSConfiguration(
				certificateURL: crt,
				privateKeyURL: pem
			)
		}
	}

	func readCommonName() -> String? {
		Self.withTLSIdentityLock {
			guard let url = Self.getUrl("commonName", ext: "txt") else {
				return nil
			}

			guard let value = try? String(contentsOf: url, encoding: .utf8)
				.trimmingCharacters(in: .whitespacesAndNewlines),
				!value.isEmpty
			else {
				return nil
			}

			return value
		}
	}
}

extension ServerInstaller {
	static func getUrl(_ name: String, ext: String) -> URL? {
		let fileManager = FileManager.default

		let serverURL = URL.documentsDirectory.appendingPathComponent("App").appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: serverURL.path) {
			return serverURL
		}

		let documentsURL = URL.documentsDirectory.appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: documentsURL.path) {
			return documentsURL
		}

		let oldServerURL = URL.documentsDirectory.appendingPathComponent("Server").appendingPathComponent("\(name).\(ext)")
		if fileManager.fileExists(atPath: oldServerURL.path) {
			return oldServerURL
		}

		return Bundle.main.url(forResource: name, withExtension: ext)
	}
	
	static func getLocalAddress() -> String? {
		var address: String?
		var ifaddr: UnsafeMutablePointer<ifaddrs>?
		guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
		defer { freeifaddrs(first) }

		var current: UnsafeMutablePointer<ifaddrs>? = first
		while let interfacePointer = current {
			let interface = interfacePointer.pointee
			if let socketAddress = interface.ifa_addr,
			   socketAddress.pointee.sa_family == UInt8(AF_INET) {
				let name = String(cString: interface.ifa_name)
				if name == "en0" || name == "pdp_ip0" {
					var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
					let result = getnameinfo(
						socketAddress,
						socklen_t(socketAddress.pointee.sa_len),
						&hostname,
						socklen_t(hostname.count),
						nil,
						0,
						NI_NUMERICHOST
					)
					if result == 0 {
						address = String(cString: hostname)
					}
				}
			}
			current = interface.ifa_next
		}
		
		return address
	}
}
