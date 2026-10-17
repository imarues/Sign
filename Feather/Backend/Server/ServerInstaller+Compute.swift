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

	/// NeoSign's GBox backup manifest expects the signed IPA to be available from
	/// its fixed loopback service at 127.0.0.1:8881/app.ipa. The ServerInstaller
	/// port is fixed to 8881 to match that protocol.
	var gboxPayloadEndpoint: URL {
		URL(string: "http://127.0.0.1:8881/app.ipa")!
	}

	/// NeoSign 5.2.0 builds the GBox backup manifest filename from:
	///     Base64("<name>/<bundle-id>/<version>") + ".plist"
	/// and prefixes it with backup_install_manifest_base_url, whose default is
	/// https://test.gbox.run/. This is the actual GBox backup path; /manifest.php
	/// belongs to NeoSign's separate cert_api_base_url and is deliberately not
	/// used here.
	var gboxManifestEndpoint: URL? {
		let identifier = app.identifier ?? ""
		let descriptor = "\(app.name)/\(identifier)/\(app.version)"
		let base64 = Data(descriptor.utf8).base64EncodedString()

		// NeoSign URL-encodes the generated path component before opening it.
		// Encode Base64 punctuation so '/' or '+' can never be interpreted as
		// another URL path level.
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

	var installManifest: [String: Any] {[
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
				"bundle-identifier": app.identifier,
				"bundle-version": app.version,
				"kind": "software",
				"title": app.name,
			],
		],],
	]}

	var installManifestData: Data {
		(try? PropertyListSerialization.data(
			fromPropertyList: installManifest,
			format: .xml,
			options: .zero
		)) ?? .init()
	}
}
