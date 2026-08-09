PROJECT := SyphonUniCamExBridge.xcodeproj
SENDER_SCHEME := SyphonUniCamExSender
RECEIVER_SCHEME := SyphonUniCamExReceiver
CONFIGURATION ?= Debug
DERIVED_DATA ?= build
SENDER_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SENDER_SCHEME).app
RECEIVER_APP := $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(RECEIVER_SCHEME).app
NETWORK_HOST ?= 127.0.0.1
NETWORK_PORT ?= 5001

# The app can be built and launched locally without a signing identity.
CODE_SIGNING_ALLOWED ?= NO

.PHONY: all generate build run run-receiver run-sender run-network clean help

all: build

generate:
	xcodegen generate

build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SENDER_SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) \
		build
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(RECEIVER_SCHEME) \
		-configuration $(CONFIGURATION) \
		-derivedDataPath $(DERIVED_DATA) \
		CODE_SIGNING_ALLOWED=$(CODE_SIGNING_ALLOWED) \
		build

run: build
	open "$(RECEIVER_APP)"

# Launch each endpoint as a separate app process. Override NETWORK_HOST and
# NETWORK_PORT for a second Mac, e.g. make run-sender NETWORK_HOST=192.168.1.42.
run-receiver: build
	open -n "$(RECEIVER_APP)" --args --port $(NETWORK_PORT)

run-sender: build
	open -n "$(SENDER_APP)" --args --host $(NETWORK_HOST) --port $(NETWORK_PORT)

run-network: build
	open -n "$(RECEIVER_APP)" --args --port $(NETWORK_PORT)
	sleep 1
	open -n "$(SENDER_APP)" --args --host $(NETWORK_HOST) --port $(NETWORK_PORT)

clean:
	rm -rf "$(DERIVED_DATA)"

help:
	@printf '%s\n' \
		'make build  Generate the Xcode project and build the app' \
		'make run    Build the app and launch it' \
		'make run-receiver  Build and launch SyphonUniCamExReceiver.app' \
		'make run-sender    Build and launch SyphonUniCamExSender.app' \
		'make run-network   Build and launch UDP receiver and sender as separate apps' \
		'make clean  Remove the local DerivedData directory' \
		'make generate  Regenerate the Xcode project'
