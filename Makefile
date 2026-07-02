SCHEME := Morbid
PROJECT := Morbid.xcodeproj
APP_NAME := Morbid
BUILD_DIR := DerivedData
INSTALL_PATH := /Applications/$(APP_NAME).app

DEBUG_APP := $(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app
RELEASE_APP := $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app

.DEFAULT_GOAL := all
.PHONY: all setup generate dev build clean open close install uninstall reinstall

all: setup dev

setup:
	@command -v xcodegen >/dev/null 2>&1 || brew install xcodegen
	xcodegen generate

generate:
	xcodegen generate

dev: generate
	rm -rf "$(DEBUG_APP)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(BUILD_DIR) build
	open "$(DEBUG_APP)"

build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(BUILD_DIR) build

clean:
	rm -rf "$(BUILD_DIR)"

open: build
	open "$(RELEASE_APP)"

close:
	-osascript -e 'tell application "$(APP_NAME)" to quit' 2>/dev/null
	-pkill -x "$(APP_NAME)" 2>/dev/null

install: build
	rm -rf "$(INSTALL_PATH)"
	cp -R "$(RELEASE_APP)" "$(INSTALL_PATH)"

uninstall: close
	rm -rf "$(INSTALL_PATH)"

reinstall: uninstall install
