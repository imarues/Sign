from pathlib import Path

lib_path = Path('Feather/Views/Library/LibraryView.swift')
s = lib_path.read_text()

old_state = '''
	/// Files selected from the Files picker are copied into app-owned temporary
	/// storage before the picker closes. That lets us ask which install mode the
	/// user wants without losing the document provider's security-scoped access.
	@State private var _pendingLocalImportURLs: [URL] = []
	@State private var _isLocalInstallChoicePresenting = false
'''
assert old_state in s, 'pending local import state not found'
s = s.replace(old_state, '\n', 1)

old_picker = '''			.fileImporter(
				isPresented: $_isImportingPresenting,
				allowedContentTypes: [.ipa, .tipa],
				allowsMultipleSelection: true
			) { result in
				switch result {
				case .success(let urls):
					_stageLocalImportsAndPresentChoice(urls)
				case .failure(let error):
					Logger.misc.error("file picker: \\(error.localizedDescription, privacy: .public)")
					UIAlertController.showAlertWithOk(
						title: "تعذر استيراد التطبيق",
						message: error.localizedDescription
					)
				}
			}
			.confirmationDialog(
				"اختر طريقة التثبيت",
				isPresented: $_isLocalInstallChoicePresenting,
				titleVisibility: .visible
			) {
				Button("تحميل وتثبيت مباشر") {
					_startPendingLocalImports(duplicate: false)
				}
				Button("تحميل وتثبيت مكرر") {
					_startPendingLocalImports(duplicate: true)
				}
				Button("إلغاء", role: .cancel) {
					_discardPendingLocalImports()
				}
			} message: {
				Text("التثبيت المكرر يغيّر معرّف Bundle بإضافة حرفين أو رقمين عشوائيين حتى يمكن تثبيت النسخة بجانب الأصلية.")
			}
'''
new_picker = '''			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						for url in urls {
							let id = "BatSignLibraryOnly_\\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							do {
								try downloadManager.handlePachageFile(url: url, dl: dl)
							} catch {
								Logger.misc.error(
									"import: \\(url.lastPathComponent, privacy: .public) — \\(error.localizedDescription, privacy: .public)"
								)
								UIAlertController.showAlertWithOk(
									title: "تعذر استيراد التطبيق",
									message: "تعذر استيراد \\(url.lastPathComponent): \\(error.localizedDescription)"
								)
							}
						}
					}
				)
				.ignoresSafeArea()
			}
'''
assert old_picker in s, 'current fileImporter block not found'
s = s.replace(old_picker, new_picker, 1)

old_url = '_ = downloadManager.startDownload(from: url, id: "FeatherManualDownload_\\(UUID().uuidString)")'
new_url = '_ = downloadManager.startDownload(from: url, id: "BatSignLibraryOnly_\\(UUID().uuidString)")'
assert old_url in s, 'manual URL import id not found'
s = s.replace(old_url, new_url, 1)

helper_start = s.index('\n\t@MainActor\n\tprivate func _stageLocalImportsAndPresentChoice')
helper_end = s.index('\n}\n\n// MARK: - Picking several', helper_start)
s = s[:helper_start] + s[helper_end:]

pill_start = s.index('\n\t@ViewBuilder\n\tprivate func _actionPill')
pill_end = s.index('\n\tprivate func _isInstalling', pill_start)
new_pill = '''
	@ViewBuilder
	private func _actionPill(_ app: any AppInfoPresentable) -> some View {
		if let update = updateManager.update(for: app) {
			WSActionButton(title: "Update") {
				_startUpdateDownload(update)
			}
		} else if app.isSigned {
			WSActionButton(title: "Open") {
				UIApplication.openApp(with: app.identifier ?? "")
			}
		} else if _isInstalling(app) {
			HStack(spacing: 8) {
				ProgressView()
					.frame(width: 16, height: 16)
				Text(.localized("Installing"))
					.font(.caption.weight(.semibold))
					.foregroundStyle(.secondary)
			}
			.frame(minWidth: 68, minHeight: 30)
		} else {
			HStack(spacing: 6) {
				_duplicateMenu(app)
				WSActionButton(title: "تثبيت") {
					_signAndInstall(app, bundleSuffix: nil)
				}
			}
		}
	}

	@ViewBuilder
	private func _duplicateMenu(_ app: any AppInfoPresentable) -> some View {
		Menu {
			Button("نسخة مكررة أولى") { _signAndInstall(app, bundleSuffix: "1") }
			Button("نسخة مكررة ثانية") { _signAndInstall(app, bundleSuffix: "2") }
			Button("نسخة مكررة ثالثة") { _signAndInstall(app, bundleSuffix: "3") }
			Button("نسخة مكررة رابعة") { _signAndInstall(app, bundleSuffix: "4") }
			Button("نسخة مكررة خامسة") { _signAndInstall(app, bundleSuffix: "5") }
			Divider()
			Button("تكرار عشوائي") {
				_signAndInstall(app, bundleSuffix: Self._randomDuplicateSuffix())
			}
		} label: {
			HStack(spacing: 4) {
				Text("تكرار")
				Image(systemName: "chevron.down")
					.font(.system(size: 9, weight: .bold))
			}
			.font(.caption.weight(.bold))
			.foregroundStyle(.primary)
			.padding(.horizontal, 12)
			.frame(minWidth: 68, minHeight: 30)
			.background {
				if #available(iOS 26.0, *) {
					Color.clear
						.glassEffect(.regular.interactive(), in: Capsule())
				} else {
					Capsule().fill(BS.chipFill)
				}
			}
		}
		.buttonStyle(.plain)
	}

	private func _signAndInstall(_ app: any AppInfoPresentable, bundleSuffix: String?) {
		var options = OptionsManager.shared.options
		options.appIdentifier = nil
		options.signingOption = .default
		options.post_installAppAfterSigned = true
		options.post_deleteAppAfterSigned = false

		if let bundleSuffix {
			guard let baseIdentifier = app.identifier, !baseIdentifier.isEmpty else {
				UIAlertController.showAlertWithOk(
					title: "تعذر إنشاء نسخة مكررة",
					message: "لا يحتوي التطبيق على Bundle ID صالح للتكرار."
				)
				return
			}
			options.appIdentifier = baseIdentifier + bundleSuffix
		}

		UIImpactFeedbackGenerator(style: .medium).impactOccurred()
		let accepted = AutoSignManager.shared.enqueue(
			app: app,
			reason: .autoSign,
			options: options,
			force: true
		)

		if !accepted {
			UIAlertController.showAlertWithOk(
				title: "تعذر بدء التثبيت",
				message: "تعذر إضافة التطبيق إلى قائمة التوقيع."
			)
		}
	}

	private static func _randomDuplicateSuffix() -> String {
		let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
		return String((0..<2).compactMap { _ in alphabet.randomElement() })
	}
'''
s = s[:pill_start] + new_pill + s[pill_end:]
lib_path.write_text(s)

handler_path = Path('Feather/Utilities/Handlers/AppFileHandler.swift')
h = handler_path.read_text()
old_flags = '''		let transferID = _download?.id
		let isAutoUpdateDownload = transferID?.hasPrefix(BatSignAuto.downloadPrefix) ?? false
		let isManualUpdateDownload = transferID?.hasPrefix(BatSignAuto.manualUpdatePrefix) ?? false
'''
new_flags = '''		let transferID = _transferID ?? _download?.id
		let isLibraryOnlyImport = transferID?.hasPrefix("BatSignLibraryOnly_") ?? false
		let isAutoUpdateDownload = transferID?.hasPrefix(BatSignAuto.downloadPrefix) ?? false
		let isManualUpdateDownload = transferID?.hasPrefix(BatSignAuto.manualUpdatePrefix) ?? false
'''
assert old_flags in h, 'transfer flags not found'
h = h.replace(old_flags, new_flags, 1)

old_route = '''		await MainActor.run {
			if SourceInstallIntent.handleIfRequested(
'''
new_route = '''		await MainActor.run {
			if isLibraryOnlyImport {
				LiveStatus.finish(
					success: true,
					appName: cardName,
					detail: "تمت الإضافة إلى المكتبة",
					appID: cardID
				)
				return
			} else if SourceInstallIntent.handleIfRequested(
'''
assert old_route in h, 'post-import route not found'
h = h.replace(old_route, new_route, 1)
handler_path.write_text(h)
