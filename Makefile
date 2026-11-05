TEAM ?= $(TZCAM_TEAM_ID)
CONFIG ?= Debug
APP := build/Build/Products/$(CONFIG)/TZCam.app

.PHONY: project build install open clean

project:
	@test -n "$(TEAM)" || (echo "Set your team ID: make install TEAM=XXXXXXXXXX" && exit 1)
	TZCAM_TEAM_ID=$(TEAM) xcodegen generate

build: project
	xcodebuild -project TZCam.xcodeproj -scheme TZCam -configuration $(CONFIG) \
		-derivedDataPath build -allowProvisioningUpdates build

# System extensions only activate from /Applications.
install: build
	-pkill -x TZCam
	rm -rf /Applications/TZCam.app
	ditto "$(APP)" /Applications/TZCam.app
	open /Applications/TZCam.app

open: project
	open TZCam.xcodeproj

clean:
	rm -rf build TZCam.xcodeproj
