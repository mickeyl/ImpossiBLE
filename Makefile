HELPER_SRC = Sources/Helper/CBSHelperMain.m
HELPER_PLIST = Sources/Helper/Info.plist
HELPER_ENTITLEMENTS = Sources/Helper/entitlements.plist
APP_BUNDLE = impossible-helper.app
APP_BIN = $(APP_BUNDLE)/Contents/MacOS/impossible-helper
INSTALL_DIR = $(HOME)/.local/bin
INSTALLED_APP = $(INSTALL_DIR)/impossible-helper.app
HELPER_BIN_NAME = impossible-helper

.PHONY: helper install clean run restart watch

helper: $(APP_BIN)

$(APP_BIN): $(HELPER_SRC) $(HELPER_PLIST) $(HELPER_ENTITLEMENTS)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS
	cp $(HELPER_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	clang -fobjc-arc -framework Foundation -framework CoreBluetooth \
		-o $(APP_BIN) $(HELPER_SRC)
	codesign --force --sign "Apple Development: Michael Lauer (BN4S5ZMC43)" --entitlements $(HELPER_ENTITLEMENTS) $(APP_BUNDLE)

install: helper
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALLED_APP)
	cp -R $(APP_BUNDLE) $(INSTALL_DIR)/

restart: install
	-pkill -f $(HELPER_BIN_NAME) 2>/dev/null; sleep 0.5
	open -a "$(INSTALLED_APP)"
	@echo "impossible-helper restarted"

run: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open -a "$(INSTALLED_APP)"; \
		echo "impossible-helper started"; \
	else \
		echo "impossible-helper already running"; \
	fi

watch: install
	@if ! pgrep -f $(HELPER_BIN_NAME) > /dev/null 2>&1; then \
		open -a "$(INSTALLED_APP)"; \
		echo "impossible-helper started"; \
	else \
		echo "impossible-helper already running"; \
	fi
	@echo "Watching for changes in Sources/Helper/…"
	@fswatch -o Sources/Helper/ | while read _; do \
		echo ""; \
		echo "=== Source changed, rebuilding… ==="; \
		if $(MAKE) install; then \
			pkill -f $(HELPER_BIN_NAME) 2>/dev/null; sleep 0.5; \
			open -a "$(INSTALLED_APP)"; \
			echo "=== Restarted ==="; \
		else \
			echo "=== Build failed ==="; \
		fi; \
	done

clean:
	rm -rf $(APP_BUNDLE)
