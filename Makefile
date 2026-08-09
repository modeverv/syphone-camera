PROJECT := SyphonUniCamExBridge.xcodeproj
SCHEME := SyphonUniCamExBridge
CONFIGURATION ?= Debug
DERIVED_DATA ?= build

# The app can be built and launched locally without a signing identity.
CODE_SIGNING_ALLOWED ?= NO

.PHONY: all generate build run clean help

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
	open "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/$(SCHEME).app"

clean:
	rm -rf "$(DERIVED_DATA)"

help:
	@printf '%s\n' \
		'make build  Generate the Xcode project and build the app' \
		'make run    Build the app and launch it' \
		'make clean  Remove the local DerivedData directory' \
		'make generate  Regenerate the Xcode project'
