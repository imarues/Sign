//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var downloadManager = DownloadManager.shared

	@State private var showInstallChoices = false

	var body: some View {
		ZStack {
			if let currentDownload = _currentDownload() {
				SourceDownloadProgress(download: currentDownload) {
					downloadManager.cancelDownload(currentDownload)
				}
			} else {
				Button {
					showInstallChoices = true
				} label: {
					Text("تحميل")
						.lineLimit(0)
						.font(.headline.bold())
						.foregroundStyle(Color.accentColor)
						.padding(.horizontal, 24)
						.padding(.vertical, 6)
						.bsGlassCapsule(interactive: true)
				}
				.buttonStyle(.borderless)
				.compatTransition()
			}
		}
		.confirmationDialog(
			"اختر طريقة التثبيت",
			isPresented: $showInstallChoices,
			titleVisibility: .visible
		) {
			Button("تحميل وتثبيت مباشر") {
				_startInstall(duplicate: false)
			}
			Button("تحميل وتثبيت مكرر") {
				_startInstall(duplicate: true)
			}
			Button("إلغاء", role: .cancel) { }
		} message: {
			Text("التثبيت المكرر ينشئ نسخة بمعرّف Bundle مختلف حتى يمكن تثبيتها بجانب النسخة الأصلية.")
		}
		// The individual Download publishes its own progress, like Ksign.
		// Avoid converting the whole queue to a String on each UI pass.
		.animation(.easeInOut(duration: 0.2), value: _currentDownload()?.id)
	}

	private func _startInstall(duplicate: Bool) {
		guard let url = app.currentDownloadUrl else { return }

		let id: String
		if duplicate {
			let suffix = Self._randomBundleSuffix()
			id = "BatSignDuplicate_\(suffix)_\(app.currentUniqueId)"
		} else {
			id = "BatSignDirect_\(app.currentUniqueId)"
		}

		_ = downloadManager.startDownload(
			from: url,
			id: id,
			bundleID: app.id,
			displayName: app.currentName,
			sourceProvenance: _sourceProvenance(),
			expectedBytes: app.size ?? 0
		)
	}

	private static func _randomBundleSuffix() -> String {
		let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
		return String((0..<2).compactMap { _ in alphabet.randomElement() })
	}

	/// The storefront can start a direct or duplicate install under an intent
	/// prefix rather than the source's normal id. Match the live transfer by URL
	/// as a fallback so the row keeps showing its real-time progress either way.
	private func _currentDownload() -> Download? {
		if let exact = downloadManager.getDownload(by: app.currentUniqueId) {
			return exact
		}
		guard let url = app.currentDownloadUrl else { return nil }
		return downloadManager.downloads.first {
			$0.url == url && $0.sourceProvenance != nil
		}
	}


	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}

private struct SourceDownloadProgress: View {
	@ObservedObject var download: Download
	let cancel: () -> Void

	private var progress: Double {
		max(0, min(1, download.overallProgress))
	}

	var body: some View {
		ZStack {
			Circle()
				.trim(from: 0, to: progress)
				.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
				.rotationEffect(.degrees(-90))
				.frame(width: 31, height: 31)

			Image(systemName: progress >= 0.75 ? "archivebox" : "square.fill")
				.foregroundStyle(.tint)
				.font(.footnote).bold()
		}
		.contentShape(Rectangle())
		.onTapGesture {
			if progress < 0.75 { cancel() }
		}
	}
}
