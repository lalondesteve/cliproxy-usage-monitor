# The Command Line Tools can build but not test (no XCTest, no swift-testing
# macro plugin), so every target uses Xcode's toolchain without xcode-select.
export DEVELOPER_DIR := /Applications/Xcode.app/Contents/Developer

APP := build/UsageMonitor.app
# Extra arguments for `make run`, e.g. a capture folder instead of the network:
# make run ARGS="--fixtures Tests/UsageCoreTests/Fixtures/synthetic/T10 --now 2026-11-22T12:00:00Z"
ARGS ?=

.PHONY: build test check-core-imports app run clean

build:
	swift build

test: check-core-imports
	swift test

# UsageCore must stay free of UI frameworks.
check-core-imports:
	@if grep -rnE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(AppKit|SwiftUI|Cocoa|UIKit)\b' Sources/UsageCore; then \
		echo "error: UsageCore imports a UI framework" >&2; exit 1; \
	fi

app:
	swift build -c release --product UsageMonitor
	scripts/bundle.sh

# Runs the bundled binary in the foreground so its log shows in the terminal.
run: app
	$(APP)/Contents/MacOS/UsageMonitor $(ARGS)

clean:
	swift package clean
	rm -rf build
