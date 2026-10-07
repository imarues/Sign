//
//  SettingsView.swift
//  Feather
//
//  BatSign's settings.
//

import SwiftUI
import NimbleViews
import UIKit
import IDeviceSwift

// MARK: - Rows
struct BSRowLabel: View {
	let glyph: BSGlyph
	var tint: Color = BS.accent
	let title: String

	var body: some View {
		HStack(spacing: 12) {
			BSIconTile(glyph: glyph, tint: tint)
			Text(.localized(title))
		}
	}
}

// MARK: - View
struct SettingsView: View {
	@ObservedObject private var _pending = BSPendingSign.shared
	@AppStorage("BatSign.autoDeleteOldVersions") private var _autoDeleteOldVersions: Bool = true
	@AppStorage("BatSign.biometricLock") private var _biometricLock: Bool = false
	@AppStorage("BatSign.defaultTab") private var _defaultTabRaw: String = TabEnum.today.rawValue
	@AppStorage("BatSign.badgeUpdates") private var _badgeUpdates: Bool = false
	@StateObject private var autoUpdateManager = AutoUpdateManager.shared
	@StateObject private var autoSignManager = AutoSignManager.shared

	var body: some View {
		NBNavigationView(.localized("Settings")) {
			Form {
				_general()
				_appearance()
				_signing()
				_automation()
				_data()
				_privacy()
				_files()
				_danger()
			}
			.environment(\.defaultMinListRowHeight, 44)
		}
	}
}

// MARK: - Sections
extension SettingsView {
	@ViewBuilder
	private func _general() -> some View {
		Section {
			Picker(selection: $_defaultTabRaw) {
				Text(.localized("Today")).tag(TabEnum.today.rawValue)
				Text(.localized("Sources")).tag(TabEnum.sources.rawValue)
				Text(.localized("Apps")).tag(TabEnum.apps.rawValue)
				Text(.localized("Library")).tag(TabEnum.library.rawValue)
			} label: {
				BSRowLabel(glyph: .launch, title: "Launch Tab")
			}
		} header: {
			Text(.localized("General"))
		} footer: {
			Text(.localized("The tab BatSign opens every time you launch it."))
		}
	}

	@ViewBuilder
	private func _appearance() -> some View {
		Section {
			NavigationLink(destination: AppearanceView()) {
				BSRowLabel(glyph: .brush, tint: .pink, title: "Appearance")
			}
		} header: {
			Text(.localized("Appearance"))
		} footer: {
			Text(.localized("Theme, tint and how the app looks on this device."))
		}
	}

	@ViewBuilder
	private func _signing() -> some View {
		Section {
			NavigationLink(destination: ConfigurationView()) {
				BSRowLabel(glyph: .sliders, tint: .purple, title: "Signing Options")
			}
			NavigationLink(destination: ArchiveView()) {
				BSRowLabel(glyph: .archive, tint: .orange, title: "Archive & Compression")
			}
			NavigationLink(destination: InstallationView()) {
				BSRowLabel(glyph: .install, title: "Installation")
			}
			NavigationLink(destination: TweakVaultView()) {
				BSRowLabel(glyph: .puzzle, tint: .mint, title: "Tweak Vault")
			}
		} header: {
			Text(.localized("Signing"))
		} footer: {
			Text(.localized("Fine-tune how apps are installed, compressed and modified. The compression mode you pick is what the Live Activity shows while a job runs."))
		}
	}

	@ViewBuilder
	private func _automation() -> some View {
		Section {
			Toggle(isOn: Binding(
				get: { autoUpdateManager.isAutoUpdateEnabled },
				set: { autoUpdateManager.isAutoUpdateEnabled = $0 }
			)) {
				BSRowLabel(glyph: .refresh, title: "Update Automatically")
			}

			Picker(selection: Binding(
				get: { Int(autoUpdateManager.intervalHours) },
				set: { autoUpdateManager.intervalHours = Double($0) }
			)) {
				Text(.localized("Hourly")).tag(1)
				Text(.localized("Every 3 Hours")).tag(3)
				Text(.localized("Every 6 Hours")).tag(6)
				Text(.localized("Every 12 Hours")).tag(12)
				Text(.localized("Daily")).tag(24)
			} label: {
				BSRowLabel(glyph: .clock, tint: .indigo, title: "Check Interval")
			}

			Picker(selection: Binding(
				get: { autoUpdateManager.isWifiOnly },
				set: { autoUpdateManager.isWifiOnly = $0 }
			)) {
				Text(.localized("Any Connection")).tag(false)
				Text(.localized("Wi-Fi Only")).tag(true)
			} label: {
				BSRowLabel(glyph: .wifi, tint: .cyan, title: "Download Over")
			}

			Picker(selection: Binding(
				get: { autoUpdateManager.isNightWindowOnly },
				set: { autoUpdateManager.isNightWindowOnly = $0 }
			)) {
				Text(.localized("Anytime")).tag(false)
				Text(.localized("Night Only")).tag(true)
			} label: {
				BSRowLabel(glyph: .moon, tint: .purple, title: "Active Window")
			}

			Picker(selection: Binding(
				get: { _pending.mode },
				set: { _pending.setMode($0) }
			)) {
				ForEach(BSSigningMode.allCases) { mode in
					Text(.localized(mode.title)).tag(mode)
				}
			} label: {
				BSRowLabel(glyph: .install, tint: .blue, title: "When Apps Arrive")
			}

			Toggle(isOn: Binding(
				get: { autoSignManager.isAutoSignEnabled },
				set: { autoSignManager.isAutoSignEnabled = $0 }
			)) {
				BSRowLabel(glyph: .quill, tint: .green, title: "Auto-Sign Imported Apps")
			}

			Toggle(isOn: Binding(
				get: { autoUpdateManager.isAutoRenewEnabled },
				set: { autoUpdateManager.isAutoRenewEnabled = $0 }
			)) {
				BSRowLabel(glyph: .shield, tint: .teal, title: "Keep Apps Signed")
			}

			Toggle(isOn: Binding(
				get: { autoUpdateManager.isSelfHealEnabled },
				set: { autoUpdateManager.isSelfHealEnabled = $0 }
			)) {
				BSRowLabel(glyph: .pulse, tint: .mint, title: "Self-Heal Revoked Apps")
			}

			Toggle(isOn: $_autoDeleteOldVersions) {
				BSRowLabel(glyph: .swap, tint: .orange, title: "Replace Old Versions")
			}
		} header: {
			Text(.localized("Automation"))
		} footer: {
			Text(.localized("One at a Time signs each app the moment it finishes downloading or importing — the default. Collect, Then Sign Together holds arriving apps in a tray instead, and they all sign as one run once you confirm. Automatic updates still sign themselves either way. An app you tap to sign is always signed immediately."))
		}
	}

	@ViewBuilder
	private func _data() -> some View {
		Section {
			NavigationLink(destination: CertificatesView()) {
				BSRowLabel(glyph: .seal, tint: .green, title: "Certificates")
			}
			NavigationLink(destination: StorageView()) {
				BSRowLabel(glyph: .drive, title: "Storage")
			}
			NavigationLink(destination: ActivityView()) {
				BSRowLabel(glyph: .activity, tint: .indigo, title: "Activity")
			}
			NavigationLink(destination: CertHealthView()) {
				BSRowLabel(glyph: .health, tint: .red, title: "Certificate Health")
			}
			NavigationLink(destination: BackupRestoreView()) {
				BSRowLabel(glyph: .transfer, tint: .brown, title: "Backup & Restore")
			}
		} header: {
			Text(.localized("Data"))
		} footer: {
			Text(.localized("Certificates used for signing apps, and storage used by the app."))
		}
	}

	@ViewBuilder
	private func _privacy() -> some View {
		Section {
			Toggle(isOn: $_biometricLock) {
				BSRowLabel(glyph: .face, title: "Face ID Lock")
			}
			Toggle(isOn: Binding(
				get: { autoUpdateManager.notificationsEnabled },
				set: { autoUpdateManager.notificationsEnabled = $0 }
			)) {
				BSRowLabel(glyph: .bell, tint: .red, title: "Notifications")
			}
			Toggle(isOn: $_badgeUpdates) {
				BSRowLabel(glyph: .badge, tint: .mint, title: "Badge App Icon")
			}
		} header: {
			Text(.localized("Privacy & Alerts"))
		} footer: {
			Text(.localized("Require Face ID to open BatSign. Progress while a job runs is shown on the Dynamic Island rather than as a notification."))
		}
	}

	@ViewBuilder
	private func _files() -> some View {
		Section {
			Button {
				UIApplication.open(URL.documentsDirectory.toSharedDocumentsURL()!)
			} label: {
				BSRowLabel(glyph: .folder, tint: .yellow, title: "Open Documents")
			}
			.foregroundStyle(.primary)

			Button {
				UIApplication.open(FileManager.default.archives.toSharedDocumentsURL()!)
			} label: {
				BSRowLabel(glyph: .archive, tint: .orange, title: "Open Archives")
			}
			.foregroundStyle(.primary)
		} header: {
			Text(.localized("Files"))
		}
	}

	@ViewBuilder
	private func _danger() -> some View {
		Section {
			NavigationLink(destination: ResetView()) {
				HStack(spacing: 12) {
					BSIconTile(glyph: .bin, tint: .red)
					Text(.localized("Reset"))
						.foregroundStyle(.red)
				}
			}
		}
	}
}
