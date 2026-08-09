PROJECT := SyphonUniCamExBridge.xcodeproj
SCHEME := SyphonUniCamExBridge
CONFIGURATION ?= Debug
DERIVED_DATA ?= build
APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SCHEME).app
NETWORK_HOST ?= 127.0.0.1
NETWORK_PORT ?= 5001
NETWORK_TRANSPORT ?= udp

# The app can be built and launched locally without a signing identity.
CODE_SIGNING_ALLOWED ?= NO

.PHONY: all generate build run run-receiver run-sender run-network clean help

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) \
		build

run: build
	open "$(APP)"

# Launch each endpoint as a separate app process. Override NETWORK_HOST and
# NETWORK_PORT for a second Mac, e.g. make run-sender NETWORK_HOST=192.168.1.42.
run-receiver: build
	open -n "$(APP)" --args --receiver --transport $(NETWORK_TRANSPORT) --port $(NETWORK_PORT)

run-sender: build
	open -n "$(APP)" --args --sender --transport $(NETWORK_TRANSPORT) --host $(NETWORK_HOST) --port $(NETWORK_PORT)

run-network: build
	open -n "$(APP)" --args --receiver --transport $(NETWORK_TRANSPORT) --port $(NETWORK_PORT)
	sleep 1
	open -n "$(APP)" --args --sender --transport $(NETWORK_TRANSPORT) --host $(NETWORK_HOST) --port $(NETWORK_PORT)

clean:
	rm -rf "$(DERIVED_DATA)"

help:
	@printf '%s\n' \
		'make build  Generate the Xcode project and build the app' \
		'make run    Build the app and launch it' \
		'make run-receiver  Build and launch the UDP H.264 receiver / UniCamEx endpoint' \
		'make run-sender    Build and launch the UDP H.264 test-pattern sender' \
		'make run-network   Build and launch UDP receiver and sender as separate apps' \
		'make clean  Remove the local DerivedData directory' \
		'make generate  Regenerate the Xcode project'
