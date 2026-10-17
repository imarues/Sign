//
//  ServerView.swift
//  Feather
//
//  Created by samara on 6.05.2025.
//  GBox install path build trigger: 2026-10-17
//

import SwiftUI
import NimbleViews

struct ServerView: View {
	@AppStorage("Feather.ipFix") private var _ipFix: Bool = false
	@AppStorage("Feather.serverMethod") private var _serverMethod: Int = 0
	@AppStorage("Feather.batchGroupSize") private var _batchGroupSize: Int = 5

	private let _serverMethods: [String] = [
		"GBox",
		.localized("Semi Local")
	]

	var body: some View {
		Group {
			Section {
				Picker(.localized("Installation Type"), systemImage: "server.rack", selection: $_serverMethod) {
					ForEach(_serverMethods.indices, id: \.self) { index in
						Text(_serverMethods[index]).tag(index)
					}
				}
				Toggle(.localized("Only use localhost address"), systemImage: "lifepreserver", isOn: $_ipFix)
					.disabled(_serverMethod != 1)
			}

			Section {
				Stepper(value: $_batchGroupSize, in: 1...100) {
					HStack {
						Image(systemName: "square.stack.3d.up")
						Text(.localized("Apps per prompt"))
						Spacer()
						Text("\(_batchGroupSize)")
							.foregroundStyle(.secondary)
					}
				}
				.disabled(_serverMethod != 0)
			} footer: {
				Text("GBox installs can share one confirmation across several apps. This sets how many apps go into each prompt. 1 gives a separate prompt per app.")
			}
		}
		.onChange(of: _serverMethod) { _ in
			UIAlertController.showAlertWithRestart(
				title: .localized("Restart Required"),
				message: .localized("These changes require a restart of the app")
			)
		}
	}
}
