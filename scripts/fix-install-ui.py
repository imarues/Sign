from pathlib import Path


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected 1 match, found {count}")
    return text.replace(old, new, 1)

# 1) The real App Store-style GET pill used by Today / Apps / Search.
p = Path("Feather/Views/Common/BSStore.swift")
s = p.read_text()
s = replace_once(s, 'case .get: return "GET"', 'case .get: return "تحميل"', "GET label")
s = replace_once(
    s,
    '@State private var presentingInstall: Signed?\n',
    '@State private var presentingInstall: Signed?\n\t@State private var showInstallChoices = false\n',
    "pill choice state",
)
s = replace_once(
    s,
    '\t\t.buttonStyle(.plain)\n\t\t.disabled(state == .unavailable || state == .signing)',
    '''\t\t.buttonStyle(.plain)\n\t\t.confirmationDialog(\n\t\t\t"اختر طريقة التثبيت",\n\t\t\tisPresented: $showInstallChoices,\n\t\t\ttitleVisibility: .visible\n\t\t) {\n\t\t\tButton("تحميل وتثبيت مباشر") {\n\t\t\t\t_startInstall(duplicate: false)\n\t\t\t}\n\t\t\tButton("تحميل وتثبيت مكرر") {\n\t\t\t\t_startInstall(duplicate: true)\n\t\t\t}\n\t\t\tButton("إلغاء", role: .cancel) { }\n\t\t} message: {\n\t\t\tText("التثبيت المكرر يغيّر معرّف Bundle بإضافة حرفين أو رقمين عشوائيين حتى يمكن تثبيت النسخة بجانب الأصلية.")\n\t\t}\n\t\t.disabled(state == .unavailable || state == .signing)''',
    "pill confirmation dialog",
)
s = replace_once(
    s,
    '''\t\tcase .get:\n\t\t\tguard let url = app.currentDownloadUrl else { return }\n\t\t\t_ = downloadManager.startDownload(\n\t\t\t\tfrom: url,\n\t\t\t\tid: app.currentUniqueId,\n\t\t\t\tbundleID: app.id,\n\t\t\t\tsourceProvenance: _provenance(),\n\t\t\t\texpectedBytes: app.size ?? 0\n\t\t\t)''',
    '''\t\tcase .get:\n\t\t\tshowInstallChoices = true''',
    "pill GET action",
)
s = replace_once(
    s,
    '\n\t// MARK: Install probe\n',
    '''\n\tprivate func _startInstall(duplicate: Bool) {\n\t\tguard let url = app.currentDownloadUrl else { return }\n\n\t\tlet id: String\n\t\tif duplicate {\n\t\t\tid = "BatSignDuplicate_\\(Self._randomBundleSuffix())_\\(app.currentUniqueId)"\n\t\t} else {\n\t\t\tid = "BatSignDirect_\\(app.currentUniqueId)"\n\t\t}\n\n\t\t_ = downloadManager.startDownload(\n\t\t\tfrom: url,\n\t\t\tid: id,\n\t\t\tbundleID: app.id,\n\t\t\tdisplayName: app.currentName,\n\t\t\tsourceProvenance: _provenance(),\n\t\t\texpectedBytes: app.size ?? 0\n\t\t)\n\t}\n\n\tprivate static func _randomBundleSuffix() -> String {\n\t\tlet alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")\n\t\treturn String((0..<2).compactMap { _ in alphabet.randomElement() })\n\t}\n\n\t// MARK: Install probe\n''',
    "pill helpers",
)
p.write_text(s)

# 2) The Apps/Search list had the pill nested inside NavigationLink, which can steal taps.
p = Path("Feather/Views/Common/BSAppList.swift")
s = p.read_text()
s = replace_once(
    s,
    '''\t\t\t\t} else {\n\t\t\t\t\tNavigationLink {\n\t\t\t\t\t\tSourceAppsDetailView(\n\t\t\t\t\t\t\tsourceURL: item.sourceURL,\n\t\t\t\t\t\t\tsource: item.source,\n\t\t\t\t\t\t\tapp: item.app\n\t\t\t\t\t\t)\n\t\t\t\t\t} label: {\n\t\t\t\t\t\tBSAppRow(item: item)\n\t\t\t\t\t}\n\t\t\t\t\t.buttonStyle(.plain)\n\t\t\t\t}''',
    '''\t\t\t\t} else {\n\t\t\t\t\tHStack(spacing: 0) {\n\t\t\t\t\t\tNavigationLink {\n\t\t\t\t\t\t\tSourceAppsDetailView(\n\t\t\t\t\t\t\t\tsourceURL: item.sourceURL,\n\t\t\t\t\t\t\t\tsource: item.source,\n\t\t\t\t\t\t\t\tapp: item.app\n\t\t\t\t\t\t\t)\n\t\t\t\t\t\t} label: {\n\t\t\t\t\t\t\tBSStoreRow(\n\t\t\t\t\t\t\t\tstoredSource: item.storedSource,\n\t\t\t\t\t\t\t\tsourceURL: item.sourceURL,\n\t\t\t\t\t\t\t\trepository: item.source,\n\t\t\t\t\t\t\t\tapp: item.app,\n\t\t\t\t\t\t\t\tshowsSeparator: false,\n\t\t\t\t\t\t\t\tshowsChevron: false,\n\t\t\t\t\t\t\t\tshowsPill: false\n\t\t\t\t\t\t\t)\n\t\t\t\t\t\t}\n\t\t\t\t\t\t.buttonStyle(.plain)\n\t\t\t\t\t\t.frame(maxWidth: .infinity)\n\n\t\t\t\t\t\tBSGetPill(sourceURL: item.sourceURL, repository: item.source, app: item.app)\n\t\t\t\t\t\t\t.padding(.trailing, 16)\n\t\t\t\t\t}\n\t\t\t\t}''',
    "independent list pill",
)
p.write_text(s)

# 3) Library file picker: remove presentation sleeps and synchronous re-copying.
p = Path("Feather/Views/Library/LibraryView.swift")
s = p.read_text()
s = replace_once(
    s,
    '.sheet(isPresented: $_isImportingPresenting, onDismiss: _presentPendingLocalInstallChoice) {',
    '.sheet(isPresented: $_isImportingPresenting, onDismiss: _showLocalInstallChoiceIfNeeded) {',
    "library picker onDismiss",
)
s = replace_once(
    s,
    '''\t\t\t\t\tonDocumentsPicked: { urls in\n\t\t\t\t\t\tguard !urls.isEmpty else { return }\n\t\t\t\t\t\t_stageLocalImports(urls)\n\t\t\t\t\t\t_isImportingPresenting = false\n\t\t\t\t\t}''',
    '''\t\t\t\t\tonDocumentsPicked: { urls in\n\t\t\t\t\t\tif urls.isEmpty {\n\t\t\t\t\t\t\t_pendingLocalImportURLs.removeAll()\n\t\t\t\t\t\t\t_isImportingPresenting = false\n\t\t\t\t\t\t\treturn\n\t\t\t\t\t\t}\n\t\t\t\t\t\t_pendingLocalImportURLs = urls\n\t\t\t\t\t\t_isImportingPresenting = false\n\t\t\t\t\t}''',
    "library picker callback",
)
s = s.replace('Button("تثبيت مباشر") {', 'Button("تحميل وتثبيت مباشر") {', 1)
s = s.replace('Button("تثبيت مكرر") {', 'Button("تحميل وتثبيت مكرر") {', 1)

old_open = '''\tprivate func _openPendingImport() {\n\t\tguard let kind = _pendingImport else { return }\n\t\t_pendingImport = nil\n\t\tTask { @MainActor in\n\t\t\ttry? await Task.sleep(nanoseconds: 450_000_000)\n\t\t\tswitch kind {\n\t\t\tcase .files: _isImportingPresenting = true\n\t\t\tcase .url: _isDownloadingPresenting = true\n\t\t\t}\n\t\t}\n\t}\n'''
new_open = '''\tprivate func _openPendingImport() {\n\t\tguard let kind = _pendingImport else { return }\n\t\t_pendingImport = nil\n\t\tDispatchQueue.main.async {\n\t\t\tswitch kind {\n\t\t\tcase .files: _isImportingPresenting = true\n\t\t\tcase .url: _isDownloadingPresenting = true\n\t\t\t}\n\t\t}\n\t}\n'''
s = replace_once(s, old_open, new_open, "open pending import")

start = s.index('\t/// Copy a provider-owned file while its security scope is still valid.')
end = s.index('\tprivate func _startPendingLocalImports(duplicate: Bool) {', start)
replacement = '''\tprivate func _showLocalInstallChoiceIfNeeded() {\n\t\tguard !_pendingLocalImportURLs.isEmpty else { return }\n\t\t_isLocalInstallChoicePresenting = true\n\t}\n\n'''
s = s[:start] + replacement + s[end:]
# Also remove any remaining old delayed presenter, if present (the block above removes it).
if '_presentPendingLocalInstallChoice' in s or '_stageLocalImports' in s:
    raise SystemExit('old delayed library import helpers still present')
# Translate the Library's own remaining Get action too.
s = s.replace('WSActionButton(title: "Get", systemImage: "arrow.down.circle")', 'WSActionButton(title: "تحميل", systemImage: "arrow.down.circle")')
p.write_text(s)

# Sanity assertions across the final source.
assert 'case .get: return "تحميل"' in Path("Feather/Views/Common/BSStore.swift").read_text()
assert 'showInstallChoices = true' in Path("Feather/Views/Common/BSStore.swift").read_text()
assert 'BatSignDuplicate_' in Path("Feather/Views/Common/BSStore.swift").read_text()
assert 'BSGetPill(sourceURL: item.sourceURL' in Path("Feather/Views/Common/BSAppList.swift").read_text()
lib = Path("Feather/Views/Library/LibraryView.swift").read_text()
assert 'Task.sleep(nanoseconds: 250_000_000)' not in lib
assert 'Task.sleep(nanoseconds: 450_000_000)' not in lib
assert 'تحميل وتثبيت مباشر' in lib and 'تحميل وتثبيت مكرر' in lib
print('installer UI fixes applied and validated')
