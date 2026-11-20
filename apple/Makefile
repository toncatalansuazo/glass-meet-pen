# Glasspen Meet — build & install
# Works even when xcode-select points at the Command Line Tools.
DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
export DEVELOPER_DIR

PROJECT   := ScreenBrush.xcodeproj
DERIVED   := build
APP_NAME  ?= Glasspen Meet
BUNDLE_ID := io.paintscreen.ScreenBrush
INSTALL_DIR ?= /Applications
MAC_APP   := $(DERIVED)/Build/Products/Release/$(APP_NAME).app
IOS_APP   := $(DERIVED)/Build/Products/Debug-iphoneos/ScreenBrushRemote.app
# First connected iPhone/iPad (override with `make phone DEVICE=<id>`).
DEVICE    ?= $(shell xcrun devicectl list devices --hide-default-columns --columns Identifier --hide-headers 2>/dev/null | grep -E '^[0-9A-F-]{20,}' | head -1)

.PHONY: all generate test build install run phone icons clean

all: install

generate:
	xcodegen generate

icons:
	swift scripts/make_icons.swift

test:
	cd BrushKit && swift test

## Release build of the Mac app, signed with your Apple Development identity.
build: generate
	xcodebuild -project $(PROJECT) -scheme ScreenBrush -configuration Release \
		-derivedDataPath $(DERIVED) -allowProvisioningUpdates -quiet build

## Installs the app into $(INSTALL_DIR) and launches it. Refuses to touch an
## existing app at that path unless it is ours (same bundle identifier).
install: build
	@dest="$(INSTALL_DIR)/$(APP_NAME).app"; \
	if [ -e "$$dest" ]; then \
		id=$$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$$dest/Contents/Info.plist" 2>/dev/null); \
		if [ "$$id" != "$(BUNDLE_ID)" ]; then \
			echo "❌ $$dest belongs to another app ($$id). Not touching it."; exit 1; \
		fi; \
		osascript -e 'tell application id "$(BUNDLE_ID)" to quit' 2>/dev/null; sleep 1; \
		rm -rf "$$dest"; \
	fi; \
	mkdir -p "$(INSTALL_DIR)" && ditto "$(MAC_APP)" "$$dest" && open "$$dest" && \
	echo "✅ Installed $$dest"

run:
	open "$(INSTALL_DIR)/$(APP_NAME).app"

## Builds Glasspen Remote and installs it on the connected iPhone/iPad.
phone: generate
	@test -n "$(DEVICE)" || (echo "No iPhone/iPad found. Connect it with a cable (or enable Wi‑Fi pairing in Xcode) and unlock it." && exit 1)
	xcodebuild -project $(PROJECT) -scheme ScreenBrushRemote -configuration Debug \
		-destination 'generic/platform=iOS' -derivedDataPath $(DERIVED) -allowProvisioningUpdates -quiet build
	xcrun devicectl device install app --device $(DEVICE) "$(IOS_APP)"
	xcrun devicectl device process launch --device $(DEVICE) io.paintscreen.ScreenBrushRemote || true
	@echo "✅ Glasspen Remote installed on $(DEVICE)"

clean:
	rm -rf $(DERIVED) build-check build-ios
