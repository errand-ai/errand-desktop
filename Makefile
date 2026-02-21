SWIFT = /usr/bin/swift
BUILD_DIR = .build/arm64-apple-macosx/debug
BINARY = $(BUILD_DIR)/ErrandDesktop
ENTITLEMENTS = ErrandDesktop.entitlements
RUN_DIR = /var/tmp/ErrandDesktop.app

.PHONY: all build sign run clean stop

all: run

build:
	$(SWIFT) build

sign: build
	codesign --force --sign - --entitlements $(ENTITLEMENTS) $(BINARY)

# Copy binary + all resource bundles to /var/tmp (vmnet workaround) and launch
run: sign stop
	@mkdir -p $(RUN_DIR)
	@cp $(BINARY) $(RUN_DIR)/ErrandDesktop
	@cp -R $(BUILD_DIR)/*.bundle $(RUN_DIR)/ 2>/dev/null || true
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) $(RUN_DIR)/ErrandDesktop
	$(RUN_DIR)/ErrandDesktop &
	@echo "Launched from $(RUN_DIR)"

stop:
	@pkill -f ErrandDesktop 2>/dev/null || true
	@sleep 0.3

clean:
	$(SWIFT) package clean
	rm -rf $(RUN_DIR)
