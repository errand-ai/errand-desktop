SWIFT = /usr/bin/swift
BUILD_DIR = .build/arm64-apple-macosx/debug
BINARY = $(BUILD_DIR)/ErrandDesktop
ENTITLEMENTS = ErrandDesktop.entitlements
APP_BUNDLE = /var/tmp/ErrandDesktop.app
CONTENTS = $(APP_BUNDLE)/Contents
MACOS_DIR = $(CONTENTS)/MacOS
RESOURCES_DIR = $(CONTENTS)/Resources

.PHONY: all build sign run clean stop

all: run

build:
	$(SWIFT) build

sign: build
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BINARY)

# Build a proper .app bundle in /var/tmp (vmnet workaround) and launch
run: sign stop
	@mkdir -p $(MACOS_DIR) $(RESOURCES_DIR)
	@cp $(BINARY) $(MACOS_DIR)/ErrandDesktop
	@cp -R $(BUILD_DIR)/*.bundle $(RESOURCES_DIR)/ 2>/dev/null || true
	@cp Sources/ErrandDesktop/Resources/AppIcon.icns $(RESOURCES_DIR)/AppIcon.icns 2>/dev/null || true
	@/usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" $(CONTENTS)/Info.plist 2>/dev/null; \
	 /usr/libexec/PlistBuddy \
	   -c "Add :CFBundleIdentifier string sh.errand.ErrandDesktop" \
	   -c "Add :CFBundleName string ErrandDesktop" \
	   -c "Add :CFBundlePackageType string APPL" \
	   -c "Add :CFBundleExecutable string ErrandDesktop" \
	   -c "Add :CFBundleIconFile string AppIcon" \
	   -c "Add :LSUIElement bool true" \
	   $(CONTENTS)/Info.plist 2>/dev/null || true
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(APP_BUNDLE)
	open $(APP_BUNDLE)
	@echo "Launched from $(APP_BUNDLE)"

stop:
	@pkill -f ErrandDesktop 2>/dev/null || true
	@sleep 0.3

clean:
	$(SWIFT) package clean
	rm -rf $(APP_BUNDLE)
