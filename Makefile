NAME := BatSign
SCHEME := Feather
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps

	-curl -fsSL "$(CERT_JSON_URL)" -o cert.json
	@if [ -f cert.json ]; then \
		jq -r '.cert' cert.json > deps/server.crt; \
		jq -r '.key1, .key2' cert.json > deps/server.pem; \
		jq -r '.info.domains.commonName' cert.json > deps/commonName.txt; \
	fi


$(PLATFORMS): deps
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project Feather.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/BatSign.app
	chmod -R 0755 _build/Payload/BatSign.app

	# Xcode's synchronized group can flatten signing-assets into the app root.
	# Rebuild the exact directory the runtime importer expects, from the repository
	# files, before the IPA is signed and packaged. Also normalize cert.txt so a
	# trailing CR/LF cannot become part of the P12 password.
	@if [ "$@" = "iphoneos" ]; then \
		ASSET_SRC="Feather/signing-assets/iKiraPlus"; \
		ASSET_DST="_build/Payload/BatSign.app/signing-assets/iKiraPlus"; \
		test -s "$$ASSET_SRC/cert.p12" || { echo "Missing signing asset: cert.p12" >&2; exit 1; }; \
		test -s "$$ASSET_SRC/cert.mobileprovision" || { echo "Missing signing asset: cert.mobileprovision" >&2; exit 1; }; \
		test -s "$$ASSET_SRC/cert.txt" || { echo "Missing signing asset: cert.txt" >&2; exit 1; }; \
		rm -f _build/Payload/BatSign.app/cert.p12 \
		      _build/Payload/BatSign.app/cert.mobileprovision \
		      _build/Payload/BatSign.app/cert.txt; \
		rm -rf _build/Payload/BatSign.app/signing-assets; \
		mkdir -p "$$ASSET_DST"; \
		cp "$$ASSET_SRC/cert.p12" "$$ASSET_DST/cert.p12"; \
		cp "$$ASSET_SRC/cert.mobileprovision" "$$ASSET_DST/cert.mobileprovision"; \
		PASSWORD=$$(tr -d '\r\n' < "$$ASSET_SRC/cert.txt"); \
		[ -n "$$PASSWORD" ] || { echo "Signing asset password is empty" >&2; exit 1; }; \
		printf '%s' "$$PASSWORD" > "$$ASSET_DST/cert.txt"; \
		cmp -s "$$ASSET_SRC/cert.p12" "$$ASSET_DST/cert.p12"; \
		cmp -s "$$ASSET_SRC/cert.mobileprovision" "$$ASSET_DST/cert.mobileprovision"; \
		[ "$$(wc -c < "$$ASSET_DST/cert.txt" | tr -d ' ')" -gt 0 ]; \
		echo "Signing assets staged at $$ASSET_DST"; \
		find _build/Payload/BatSign.app/signing-assets -maxdepth 3 -type f -print; \
	fi

	codesign --force --sign - --timestamp=none _build/Payload/BatSign.app
	cp deps/* _build/Payload/BatSign.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/BatSign.ipa"; \
		unzip -l "packages/BatSign.ipa" | grep -E 'Payload/BatSign.app/signing-assets/iKiraPlus/(cert\.p12|cert\.mobileprovision|cert\.txt)' | tee /tmp/batsign-signing-assets.txt; \
		[ "$$(wc -l < /tmp/batsign-signing-assets.txt | tr -d ' ')" -eq 3 ] || { echo "IPA signing-assets verification failed" >&2; exit 1; }; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/BatSign.app "packages/BatSign_Catalyst.zip"; \
	fi
