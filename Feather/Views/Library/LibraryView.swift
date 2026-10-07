//
//  LibraryView.swift
//  Feather
//
//  From-scratch App Store-style library surface.
//

import SwiftUI
import CoreData
import NimbleViews
import OSLog
import UIKit

// MARK: - View
struct LibraryView: View {
	@StateObject var downloadManager = DownloadManager.shared
	@StateObject var updateManager = UpdateManager.shared
	@ObservedObject private var autoSignManager = AutoSignManager.shared
	@ObservedObject private var _bulk = BSBulkSign.shared

	/// Whether apps are being picked to sign as one run.
	@State private var _isSelecting = false
	/// The picked apps, by uuid. A `Set` because the only questions ever asked
	/// of it are membership and count.
	@State private var _selection: Set<String> = []

	@State private var _selectedInfoAppPresenting: AnyApp?
	@State private var _selectedSigningAppPresenting: AnyApp?
	@State private var _selectedInstallAppPresenting: AnyApp?
	@State private var _isImportingPresenting = false
	@State private var _isDownloadingPresenting = false
	/// Whether the Add App sheet — the two ways in — is up.
	@State private var _isAddChoicePresenting = false
	/// The way in the sheet picked; opened once the sheet is fully gone, since
	/// a sheet that is still coming down will not make room for the next one.
	private enum _PendingImport { case files, url }
	@State private var _pendingImport: _PendingImport?
	@State private var _alertDownloadString = ""


	@State private var _searchText = ""
	@State private var _selectedScope: Scope = .all

	// MARK: Fetch
	@FetchRequest(
		entity: Signed.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Signed.date, ascending: false)],
		animation: .snappy
	) private var _signedApps: FetchedResults<Signed>

	@FetchRequest(
		entity: Imported.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \Imported.date, ascending: false)],
		animation: .snappy
	) private var _importedApps: FetchedResults<Imported>

	@FetchRequest(
		entity: AltSource.entity(),
		sortDescriptors: [NSSortDescriptor(keyPath: \AltSource.name, ascending: true)],
		animation: .snappy
	) private var _sources: FetchedResults<AltSource>

	private var _filteredSigned: [Signed] {
		_signedApps.filter { _matches($0.name) }
	}

	private var _filteredImported: [Imported] {
		_importedApps.filter { _matches($0.name) }
	}

	private var _showSigned: Bool {
		_selectedScope == .all || _selectedScope == .signed
	}

	private var _showImported: Bool {
		_selectedScope == .all || _selectedScope == .imported
	}

	private var _isCompletelyEmpty: Bool {
		_filteredSigned.isEmpty && _filteredImported.isEmpty
	}

	private func _matches(_ name: String?) -> Bool {
		_searchText.isEmpty || (name?.localizedCaseInsensitiveContains(_searchText) ?? false)
	}

	// MARK: Body
	var body: some View {
		NavigationStack {
			ScrollView {
				VStack(alignment: .leading, spacing: 22) {
					// What has arrived and is waiting to be signed, above the list it
					// is waiting in. Absent on the one-at-a-time system, because
					// then there is never anything waiting.
					BSPendingSignStrip()

					// The run, above the list it was picked from: one button, several
					// apps, and this is where it says how far it has got.
					BSBulkSignStrip()

					Text(_countText.uppercased())
						.font(BSStore.eyebrowFont)
						.foregroundStyle(BSStore.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)

					_searchBar()
					if _showSigned && !_filteredSigned.isEmpty {
						_appSection(title: "Installed", apps: _filteredSigned)
					}

					if _showImported && !_filteredImported.isEmpty {
						_appSection(title: "Ready to Install", apps: _filteredImported)
					}

					if _isCompletelyEmpty {
						_emptyCard()
					}
				}
				.padding(.horizontal, 16)
				.padding(.top, 4)
				.padding(.bottom, 28)
			}
			.bsScreen()
			.bsChrome()
			// The bar that starts a run sits over the list's own bottom edge, so
			// the last row is never hidden behind it and the bar is never
			// scrolled away from the answer it is about to act on.
			.safeAreaInset(edge: .bottom) {
				if _isSelecting {
					BSBulkActionBar(
						count: _selection.count,
						title: _bulkTitle,
						action: _startBulkSign,
						selectAll: _toggleSelectAll,
						cancel: _endSelecting
					)
				}
			}
			.animation(.snappy(duration: 0.22), value: _isSelecting)
			.navigationTitle(.localized("Library"))
			.navigationBarTitleDisplayMode(.large)
			.toolbar {
				ToolbarItem(placement: .topBarLeading) {
					if !_isCompletelyEmpty {
						Button(_isSelecting ? "Done" : "Select") {
							BSHaptics.tap()
							withAnimation(.snappy(duration: 0.22)) {
								_isSelecting.toggle()
								if !_isSelecting { _selection.removeAll() }
							}
						}
						.font(.body.weight(_isSelecting ? .semibold : .regular))
					}
				}
				ToolbarItem(placement: .topBarTrailing) {
					Button {
						BSHaptics.tap()
						_isAddChoicePresenting = true
					} label: {
						HStack(spacing: 6) {
							Image(systemName: "plus")
							Text("إضافة تطبيق")
						}
						.font(.body.weight(.semibold))
					}
					.accessibilityLabel("إضافة تطبيق")
				}
			}
			.sheet(isPresented: $_isAddChoicePresenting, onDismiss: _openPendingImport) {
				_addAppSheet()
					.presentationDetents([.height(250)])
					.presentationDragIndicator(.visible)
					.modifier(BSSheetGround(color: BS.screen))
			}
			.refreshable {
				await _checkForUpdates()
			}
			.sheet(item: $_selectedInfoAppPresenting) { app in
				LibraryInfoView(app: app.base)
			}
			.sheet(item: $_selectedInstallAppPresenting) { app in
				InstallPreviewView(app: app.base, isSharing: app.archive)
					.presentationDetents([.height(200)])
					.presentationDragIndicator(.visible)
			}
			.sheet(item: $_selectedSigningAppPresenting) { app in
				SigningView(app: app.base)
			}
			.sheet(isPresented: $_isImportingPresenting) {
				FileImporterRepresentableView(
					allowedContentTypes: [.ipa, .tipa],
					allowsMultipleSelection: true,
					onDocumentsPicked: { urls in
						guard !urls.isEmpty else { return }
						for url in urls {
							let id = "BatSignLibraryOnly_\(UUID().uuidString)"
							let dl = downloadManager.startArchive(from: url, id: id)
							do {
								try downloadManager.handlePachageFile(url: url, dl: dl)
							} catch {
								Logger.misc.error(
									"import: \(url.lastPathComponent, privacy: .public) — \(error.localizedDescription, privacy: .public)"
								)
								UIAlertController.showAlertWithOk(
									title: "تعذر استيراد التطبيق",
									message: "تعذر استيراد \(url.lastPathComponent): \(error.localizedDescription)"
								)
							}
						}
					}
				)
				.ignoresSafeArea()
			}
			.alert("استيراد من رابط", isPresented: $_isDownloadingPresenting) {
				TextField("الرابط", text: $_alertDownloadString)
					.textInputAutocapitalization(.never)
				Button("إلغاء", role: .cancel) {
					_alertDownloadString = ""
				}
				Button("موافق") {
					if let url = URL(string: _alertDownloadString) {
						_ = downloadManager.startDownload(from: url, id: "BatSignLibraryOnly_\(UUID().uuidString)")
					}
				}
			}
			.onReceive(NotificationCenter.default.publisher(for: Notification.Name("Feather.installApp"))) { _ in
				if let latest = _signedApps.first {
					_selectedInstallAppPresenting = AnyApp(base: latest)
				}
			}
			#if DEBUG
			.onAppear {
				if CommandLine.arguments.contains("-select") {
					Task { @MainActor in
						try? await Task.sleep(nanoseconds: 1_200_000_000)
						withAnimation(.snappy(duration: 0.22)) { _isSelecting = true }
						try? await Task.sleep(nanoseconds: 600_000_000)
						_toggleSelectAll()
					}
				}

				if CommandLine.arguments.contains("-addchoice") {
					Task { @MainActor in
						try? await Task.sleep(nanoseconds: 1_500_000_000)
						_isAddChoicePresenting = true
					}
				}
			}
			#endif
		}
	}
}

// MARK: - Add App sheet

/// The sheet's presentation backdrop, set to a colour the content already
/// paints, on every iOS this app runs on. `presentationBackground(_:)` exists
/// only from iOS 16.4, and below it a sheet's backdrop is the system's material
/// — which is exactly the mismatch this is here to remove — so older OSes get
/// the same answer through UIKit's own presentation API.
struct BSSheetGround: ViewModifier {
	let color: Color

	func body(content: Content) -> some View {
		if #available(iOS 16.4, *) {
			content.presentationBackground(color)
		} else {
			content.background(
				SheetBackdropSetter(color: UIColor(color))
			)
		}
	}
}

/// Hands a colour to the presenting sheet's UIKit backing, for iOS versions
/// without the SwiftUI modifier.
private struct SheetBackdropSetter: UIViewControllerRepresentable {
	let color: UIColor

	func makeUIViewController(context: Context) -> UIViewController {
		UIViewController()
	}

	func updateUIViewController(_ controller: UIViewController, context: Context) {
		guard let sheet = controller.presentingViewController?.sheetPresentationController ??
			      controller.view.window?.rootViewController?.presentedViewController?.sheetPresentationController else { return }
		sheet.presentedView?.backgroundColor = color
	}
}

extension LibraryView {
	/// The Add App list sheet: the two ways in as rows in a list — the shape
	/// every iOS draws the same, whatever the window's size class thinks it is.
	private func _addAppSheet() -> some View {
		VStack(alignment: .leading, spacing: 14) {
			Text("إضافة تطبيق")
				.font(.system(size: 22, weight: .bold, design: .rounded))
			Text("اختر مصدر التطبيق.")
				.font(.system(size: 15))
				.foregroundStyle(.secondary)

			VStack(spacing: 0) {
				Button {
					_chooseImport(.files)
				} label: {
					_addAppRow(
						title: "استيراد من الملفات",
						subtitle: "اختر ملفاً من تطبيق الملفات",
						icon: "folder"
					)
				}
				.buttonStyle(.plain)

				Rectangle()
					.fill(Color.primary.opacity(0.08))
					.frame(height: 0.5)
					.padding(.leading, 68)

				Button {
					_chooseImport(.url)
				} label: {
					_addAppRow(
						title: "استيراد من رابط",
						subtitle: "الصق رابط التطبيق",
						icon: "link"
					)
				}
				.buttonStyle(.plain)
			}
			.bsCard(cornerRadius: BS.radiusCard)
		}
		.padding(.horizontal, 20)
		.padding(.top, 26)
		.padding(.bottom, 14)
		.frame(maxWidth: .infinity, alignment: .leading)
		.bsScreen()
	}

	private func _addAppRow(title: String, subtitle: String, icon: String) -> some View {
		HStack(spacing: 14) {
			ZStack {
				Circle()
					.fill(Color.primary.opacity(0.06))
				Image(systemName: icon)
					.font(.system(size: 16, weight: .semibold))
					.foregroundStyle(BS.accent)
			}
			.frame(width: 36, height: 36)

			VStack(alignment: .leading, spacing: 2) {
				Text(title)
					.font(.system(size: 17, weight: .semibold))
					.lineLimit(1)
				Text(subtitle)
					.font(.system(size: 14))
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer(minLength: 8)

			Image(systemName: "chevron.forward")
				.font(.footnote.weight(.semibold))
				.foregroundStyle(.tertiary)
		}
		.padding(.horizontal, 16)
		.padding(.vertical, 13)
		.contentShape(Rectangle())
	}

	private func _chooseImport(_ kind: _PendingImport) {
		_pendingImport = kind
		_isAddChoicePresenting = false
	}

	private func _openPendingImport() {
		guard let kind = _pendingImport else { return }
		_pendingImport = nil
		DispatchQueue.main.async {
			switch kind {
			case .files: _isImportingPresenting = true
			case .url: _isDownloadingPresenting = true
			}
		}
	}

}

// MARK: - Picking several

extension LibraryView {
	/// Everything this screen can sign: the apps already installed, then the
	/// imports waiting to be installed — the order the list is read in, so
	/// "sign the first three" means the three at the top of the screen.
	private var _pickableApps: [any AppInfoPresentable] {
		var apps: [any AppInfoPresentable] = []
		if _showSigned {
			apps.append(contentsOf: _filteredSigned.map { $0 as any AppInfoPresentable })
		}
		if _showImported {
			apps.append(contentsOf: _filteredImported.map { $0 as any AppInfoPresentable })
		}
		return apps
	}

	private func _isPicked(_ app: any AppInfoPresentable) -> Bool {
		guard let uuid = app.uuid else { return false }
		return _selection.contains(uuid)
	}

	private func _togglePick(_ app: any AppInfoPresentable) {
		guard let uuid = app.uuid else { return }
		BSHaptics.tap()
		withAnimation(.snappy(duration: 0.2)) {
			if _selection.contains(uuid) {
				_selection.remove(uuid)
			} else {
				_selection.insert(uuid)
			}
		}
	}

	private var _bulkTitle: String {
		_selection.count == 1 ? "Sign 1 App" : "Sign \(_selection.count) Apps"
	}

	/// One run, from the apps picked. The queue does the work and the cards say
	/// what it is doing; this only has to hand it the list in the right order.
	private func _startBulkSign() {
		let apps = _pickableApps.filter { _isPicked($0) }
		guard !apps.isEmpty else { return }

		let started = BSBulkSign.shared.sign(apps, title: _bulkTitle)
		_endSelecting()

		if started == 0 {
			UINotificationFeedbackGenerator().notificationOccurred(.warning)
		}
	}

	private func _toggleSelectAll() {
		let uuids = _pickableApps.compactMap { $0.uuid }
		withAnimation(.snappy(duration: 0.2)) {
			if _selection.count >= uuids.count {
				_selection.removeAll()
			} else {
				_selection = Set(uuids)
			}
		}
	}

	private func _endSelecting() {
		withAnimation(.snappy(duration: 0.22)) {
			_isSelecting = false
			_selection.removeAll()
		}
	}
}

// MARK: - Sections
extension LibraryView {
	private var _countText: String {
		let total = _filteredSigned.count + _filteredImported.count
		return total == 1 ? "1 APP" : "\(total) APPS"
	}

	@ViewBuilder
	private func _searchBar() -> some View {
		HStack(spacing: 8) {
			Image(systemName: "magnifyingglass")
				.foregroundStyle(.secondary)
			TextField("Search apps", text: $_searchText)
				.textInputAutocapitalization(.never)
				.autocorrectionDisabled()
			if !_searchText.isEmpty {
				Button {
					_searchText = ""
				} label: {
					Image(systemName: "xmark.circle.fill")
						.foregroundStyle(.tertiary)
				}
			}
		}
		.padding(.horizontal, 12)
		.padding(.vertical, 10)
		.background(
			RoundedRectangle(cornerRadius: 14, style: .continuous)
				.fill(BS.cardFill)
		)

		Picker("", selection: $_selectedScope) {
			Text("All").tag(Scope.all)
			Text("Installed").tag(Scope.signed)
			Text("Imports").tag(Scope.imported)
		}
		.pickerStyle(.segmented)
	}

	@ViewBuilder
	private func _appSection(title: String, apps: [any AppInfoPresentable]) -> some View {
		VStack(alignment: .leading, spacing: 12) {
			WSSectionTitle(title: title, actionTitle: "\(apps.count)")

			VStack(spacing: 10) {
				ForEach(apps, id: \.uuid) { app in
					_appCard(app)
				}
			}
		}
	}

	@ViewBuilder
	private func _appCard(_ app: any AppInfoPresentable) -> some View {
		HStack(spacing: 14) {
			if _isSelecting {
				Image(systemName: _isPicked(app) ? "checkmark.circle.fill" : "circle")
					.font(.system(size: 22, weight: .regular))
					.foregroundStyle(_isPicked(app) ? BS.accent : Color.secondary.opacity(0.45))
					.transition(.scale(scale: 0.7).combined(with: .opacity))
			}

			FRAppIconView(app: app, size: 57)
				.overlay(alignment: .topTrailing) {
					if updateManager.update(for: app) != nil {
						Circle()
							.fill(Color.accentColor)
							.frame(width: 10, height: 10)
							.offset(x: 4, y: -4)
					}
				}

			VStack(alignment: .leading, spacing: 3) {
				Text(app.name ?? "Unknown")
					.font(.body.weight(.semibold))
					.foregroundStyle(.primary)
					.lineLimit(1)
				Text(verbatim: app.version ?? "")
					.font(.caption)
					.foregroundStyle(.secondary)
					.lineLimit(1)
			}

			Spacer()

			if !_isSelecting {
				_actionPill(app)
			}
		}
		.padding(14)
		.background(
			RoundedRectangle(cornerRadius: 20, style: .continuous)
				.fill(BS.cardFill)
		)
		.overlay(
			RoundedRectangle(cornerRadius: 20, style: .continuous)
				.strokeBorder(
					_isSelecting && _isPicked(app) ? BS.accent.opacity(0.55) : .clear,
					lineWidth: 1.5
				)
		)
		.contentShape(Rectangle())
		.onTapGesture {
			guard _isSelecting else { return }
			_togglePick(app)
		}
		.contextMenu {
			if !_isSelecting {
				_contextActions(app)
			}
		}
		.animation(.snappy(duration: 0.2), value: _isSelecting)
		.animation(.snappy(duration: 0.2), value: _selection)
	}

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

	private func _isInstalling(_ app: any AppInfoPresentable) -> Bool {
		let jobs = (autoSignManager.currentJob.map { [$0] } ?? []) + autoSignManager.queue
		return jobs.contains { $0.appIdentifier == app.identifier }
	}

	@ViewBuilder
	private func _contextActions(_ app: any AppInfoPresentable) -> some View {
		Button {
			_selectedInfoAppPresenting = AnyApp(base: app)
		} label: {
			Label("Get Info", systemImage: "info.circle")
		}

		if let update = updateManager.update(for: app) {
			Button {
				_startUpdateDownload(update)
			} label: {
				Label("Update", systemImage: "arrow.down.circle")
			}
		}

		if app.isSigned {
			Button {
				UIApplication.openApp(with: app.identifier ?? "")
			} label: {
				Label("Open", systemImage: "app.badge.checkmark")
			}
			Button {
				_selectedInstallAppPresenting = AnyApp(base: app)
			} label: {
				Label("Install", systemImage: "square.and.arrow.down")
			}
			Button {
				_selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label("Re-sign", systemImage: "signature")
			}
			Button {
				UIImpactFeedbackGenerator(style: .medium).impactOccurred()
				AutoSignManager.shared.cloneApp(app: app)
			} label: {
				Label("Clone App", systemImage: "plus.square.on.square")
			}
			Button {
				_selectedInstallAppPresenting = AnyApp(base: app, archive: true)
			} label: {
				Label("Export", systemImage: "square.and.arrow.up")
			}
		} else {
			Button {
				_selectedInstallAppPresenting = AnyApp(base: app)
			} label: {
				Label("Install", systemImage: "square.and.arrow.down")
			}
			Button {
				_selectedSigningAppPresenting = AnyApp(base: app)
			} label: {
				Label("Sign", systemImage: "signature")
			}
			Button {
				UIImpactFeedbackGenerator(style: .medium).impactOccurred()
				AutoSignManager.shared.cloneApp(app: app)
			} label: {
				Label("Clone App", systemImage: "plus.square.on.square")
			}
		}

		Divider()

		Button(role: .destructive) {
			if let identifier = app.identifier {
				BSInstallWatcher.shared.retireFromLibrary(identifier)
			}
			Storage.shared.deleteApp(for: app)
		} label: {
			Label("Remove", systemImage: "trash")
		}
	}

	private func _emptyCard() -> some View {
		VStack(spacing: 12) {
			Image(systemName: "square.stack.3d.up.slash")
				.font(.system(size: 34, weight: .regular))
				.foregroundStyle(BSStore.tertiary)
			Text("No Apps Yet")
				.font(.system(size: 20, weight: .bold, design: .rounded))
			Text("Import an app or grab one from your sources.")
				.font(.system(size: 14))
				.foregroundStyle(BSStore.secondary)
				.multilineTextAlignment(.center)
				.padding(.horizontal, 24)
		}
		.frame(maxWidth: .infinity)
		.padding(.vertical, 48)
	}
}

// MARK: - Actions
extension LibraryView {
	enum Scope: CaseIterable {
		case all
		case signed
		case imported
	}

	private func _checkForUpdates() async {
		let localApps = _signedApps.map { $0 as AppInfoPresentable }
			+ _importedApps.map { $0 as AppInfoPresentable }
		await updateManager.checkForUpdates(
			sources: Array(_sources),
			localApps: localApps
		)
	}

	private func _startUpdateDownload(_ update: AppUpdate) {
		UIImpactFeedbackGenerator(style: .light).impactOccurred()
		_ = DownloadManager.shared.startDownload(
			from: update.downloadURL,
			id: "\(BatSignAuto.manualUpdatePrefix)_\(update.localUUID)",
			sourceProvenance: update.sourceProvenance
		)
	}
}
