BIN_DIR ?= $(HOME)/.local/bin

.PHONY: build install

build:
	swift build -c release

# Replaces the installed binary and starts the daemon again.
# `kill` fails when no daemon runs: ignore that error.
# `rm` first: a copy onto the old file can make macOS refuse the code signature.
install: build
	-macpixel kill
	mkdir -p $(BIN_DIR)
	rm -f $(BIN_DIR)/macpixel
	cp .build/release/macpixel $(BIN_DIR)/
	$(BIN_DIR)/macpixel install
