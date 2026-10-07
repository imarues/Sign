//
//  DownloadButtonView.swift
//  Feather
//
//  Created by samsam on 7/25/25.
//

import SwiftUI
import Combine
import AltSourceKit
import NimbleViews

struct DownloadButtonView: View {
	let sourceURL: URL?
	let source: ASRepository?
	let app: ASRepository.App
	@ObservedObject private var downloadManager = DownloadManager.shared

	@State private var downloadProgress: Double = 0
	@State private var cancellable: AnyCancellable?
	@State private var showInstallChoices = false

	var body: some View {
		ZStack {
			if let currentDownload = _currentDownload() {
				ZStack {
					Circle()
						.trim(from: 0, to: downloadProgress)
						.stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
						.rotationEffect(.degrees(-90))
						.frame(width: 31, height: 31)
						.animation(.smooth, value: downloadProgress)

					Image(systemName: downloadProgress >= 0.75 ? "archivebox" : "square.fill")
						.foregroundStyle(.tint)
						.font(.footnote).bold()
				}
				.onTapGesture {
					if downloadProgress <= 0.75 {
						downloadManager.cancelDownload(currentDownload)
					}
				}
				.compatTransition()
			} else {
				Button {
					showInstallChoices = true
				} label: {
					Text(.localized("Get"))
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
		.onAppear(perform: setupObserver)
		.onDisappear { cancellable?.cancel() }
		.onChange(of: downloadManager.downloads.description) { _ in
			setupObserver()
		}
		.animation(.easeInOut(duration: 0.3), value: _currentDownload() != nil)
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
		setupObserver()
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

	private func setupObserver() {
		cancellable?.cancel()
		guard let download = _currentDownload() else {
			downloadProgress = 0
			return
		}
		downloadProgress = download.overallProgress

		let publisher = Publishers.CombineLatest(
			download.$progress,
			download.$unpackageProgress
		)

		cancellable = publisher.sink { _, _ in
			downloadProgress = download.overallProgress
		}
	}
	
	private func _sourceProvenance() -> SourceAppProvenance? {
		guard let source else { return nil }
		return SourceAppProvenance(sourceURL: sourceURL, repository: source, app: app)
	}
}
