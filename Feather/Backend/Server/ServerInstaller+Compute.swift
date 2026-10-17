//
//  Server+Compute.swift
//  feather
//
//  Created by samara on 22.08.2024.
//  Copyright © 2024 Lakr Aream. All Rights Reserved.
//  ORIGINALLY LICENSED UNDER GPL-3.0, MODIFIED FOR USE FOR FEATHER
//

import Foundation
import UIKit.UIGraphicsImageRenderer

extension ServerInstaller {
	/// The URL for one of this server's own routes.
	private func endpointURL(path: String, secure: Bool) -> URL {
		var comps = URLComponents()
		func build(host: String) -> URL? {
			comps.scheme = secure ? "https" : "http"
			comps.host = host
			comps.path = path
			comps.port = port
			return comps.url
		}

		return build(host: sni())
			?? build(host: "127.0.0.1")
			?? URL(fileURLWithPath: path)
	}

	private var manifestName: String {
		let value = app.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return value.isEmpty ? "App" : value
	}

	private var manifestIdentifier: String? {
		let value = app.identifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return value.isEmpty ? nil : value
	}

	private var manifestVersion: String {
		let value = app.version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
		return value.isEmpty ? "1.0" : value
	}

	/// NeoSign's GBox backup manifest expects the signed IPA to be available from
	/// its fixed loopback service at 127.0.0.1:8881/app.ipa. The ServerInstaller
	/// port is fixed to 8881 to match that protocol.
	var gboxPayloadEndpoint: URL {
		URL(string: "http://127.0.0.1:8881/app.ipa")!
	}

	/// NeoSign 5.2.0 builds the GBox backup manifest filename from:
	///     unpaddedBase64("<name>/<bundle-id>/<version>") + ".plist"
	/// and prefixes it with backup_install_manifest_base_url, whose default is
	/// https://test.gbox.run/.
	///
	/// Do not interpolate AppInfoPresentable optionals directly here. Swift turns
	/// an optional String into text such as Optional("1Contact"), which changes
	/// the Base64 key and makes GBox generate an invalid manifest/title.
	var gboxManifestEndpoint: URL? {
		guard let identifier = manifestIdentifier else { return nil }
		let descriptor = "\(manifestName)/\(identifier)/\(manifestVersion)"
		let base64 = Data(descriptor.utf8)
			.base64EncodedString()
			.trimmingCharacters(in: CharacterSet(charactersIn: "="))

		// Keep the Base64 value as one URL path component. Percent-encoding only
		// protects punctuation that would otherwise be interpreted as URL syntax;
		// the server receives the decoded Base64 filename.
		var allowed = CharacterSet.alphanumerics
		allowed.insert(charactersIn: "-._~")
		guard let encoded = base64.addingPercentEncoding(withAllowedCharacters: allowed) else {
			return nil
		}

		return URL(string: "https://test.gbox.run/\(encoded).plist")
	}

	/// Local endpoints are retained as a fallback/debug route.
	private var isSecure: Bool {
		getServerMethod() != 1 && usesTLS
	}

	var plistEndpoint: URL {
		endpointURL(path: "/\(id).plist", secure: isSecure)
	}

	var payloadEndpoint: URL {
		endpointURL(path: "/\(id).ipa", secure: isSecure)
	}

	var pageEndpoint: URL {
		endpointURL(path: "/install", secure: isSecure)
	}

	/// GBox is the primary OTA manifest provider. If the GBox URL cannot be
	/// constructed, keep the local manifest route as a last-resort fallback.
	var externalServerLink: String {
		gboxManifestEndpoint?.absoluteString ?? plistEndpoint.absoluteString
	}

	var iTunesLink: String {
		_iTunesLink(with: externalServerLink)
	}

	var iTunesLinkExternal: String {
		_iTunesLink(with: externalServerLink)
	}

	var iTunesLinkLocal: String {
		_iTunesLink(with: plistEndpoint.absoluteString)
	}

	private func _iTunesLink(with url: String) -> String {
		var components = URLComponents()
		components.scheme = "itms-services"
		components.host = ""
		components.queryItems = [
			URLQueryItem(name: "action", value: "download-manifest"),
			URLQueryItem(name: "url", value: url),
		]
		return components.string ?? "itms-services://?action=download-manifest"
	}

	var displayImageSmallEndpoint: URL {
		endpointURL(path: "/app57x57.png", secure: isSecure)
	}

	var displayImageLargeEndpoint: URL {
		endpointURL(path: "/app512x512.png", secure: isSecure)
	}

	var displayImageSmallData: Data {
		_createIcon(57)
	}

	var displayImageLargeData: Data {
		_createIcon(512)
	}
	
	private func _createIcon(_ r: CGFloat) -> Data {
		let renderer = UIGraphicsImageRenderer(size: .init(width: r, height: r))
		let image = renderer.image { ctx in
			UIColor.tintColor.setFill()
			ctx.fill(.init(x: 0, y: 0, width: r, height: r))
		}
		return image.pngData() ?? Data()
	}

	var html: String {
		"""
		<html style="background-color: black;">
		<script type="text/javascript">window.location="\(iTunesLink)"</script>
		</html>
		"""
	}

	var installManifest: [String: Any] {
		guard let identifier = manifestIdentifier else { return [:] }
		return [
			"items": [[
				"assets": [
					[
						"kind": "software-package",
						"url": payloadEndpoint.absoluteString,
					],
					[
						"kind": "display-image",
						"url": displayImageSmallEndpoint.absoluteString,
					],
					[
						"kind": "full-size-image",
						"url": displayImageLargeEndpoint.absoluteString,
					],
				],
				"metadata": [
					"bundle-identifier": identifier,
					"bundle-version": manifestVersion,
					"kind": "software",
					"title": manifestName,
				],
			]],
		]
	}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
