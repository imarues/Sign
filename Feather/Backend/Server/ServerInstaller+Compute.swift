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

	/// GBox 6.1.3 starts its local HTTPServer on port 9800 and serves the signed
	/// archive from .InstallPackage/app.ipa. Mirror that protocol exactly.
	var gboxPayloadEndpoint: URL {
		URL(string: "http://127.0.0.1:9800/app.ipa")!
	}

	/// Use GBox's own production install manifest instead of NeoSign's backup
	/// manifest service. The current GBox binary builds this exact URL after
	/// starting its local server on port 9800.
	var gboxManifestEndpoint: URL? {
		URL(string: "https://i.gbox.run/install.plist")
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
