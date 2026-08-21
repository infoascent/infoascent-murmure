EXEC     := InfoAscentMurmure
CONFIG   := debug

## Build products live OUTSIDE this directory, for the same reason the .app does.
##
## ~/Desktop is iCloud/file-provider synced, and the provider mutates files inside
## .build while the compiler is using them — producing "input file was modified during
## the build" on random object files, and occasionally a wedged swift-frontend stuck at
## 0% CPU. Moving the scratch path to ~/Library/Caches (never synced) removes the race.
SCRATCH  := $(HOME)/Library/Caches/InfoAscentMurmureBuild/scratch
BUILD    := $(SCRATCH)/$(CONFIG)/$(EXEC)

## The bundle is assembled and signed OUTSIDE this directory on purpose.
##
## This tree lives under ~/Desktop, which is iCloud/file-provider synced. The provider
## stamps com.apple.FinderInfo onto files inside an .app faster than we can strip them,
## and codesign hard-refuses anything carrying them ("resource fork, Finder information,
## or similar detritus not allowed"). `xattr -cr` immediately before signing is not enough
## — the provider re-stamps in between. Staging in ~/Library/Caches sidesteps it entirely.
STAGE    := $(HOME)/Library/Caches/InfoAscentMurmureBuild
APPNAME  := InfoAscent Murmure.app
BUNDLE   := $(STAGE)/$(APPNAME)
CONTENTS := $(BUNDLE)/Contents

## TCC keys the Accessibility grant to the code signature, so an ad-hoc signature — which
## changes on every build — makes the user re-grant after every `make`. Signing with a
## stable Developer ID keeps the identity constant and the grant sticky. Falls back to
## ad-hoc ("-") on a machine without the cert.
## Prefers a real Developer ID, falls back to the locally-generated "Murmur Local Signing"
## certificate, and only then to ad-hoc. The local certificate exists for exactly one
## reason: TCC binds the Accessibility grant to the signing identity, and an ad-hoc
## signature is regenerated on every build — so every `make install` silently revoked
## Accessibility, CGEventTapCreate then failed, and the push-to-talk key did nothing at all
## with no user-visible error. A stable identity keeps the grant across rebuilds.
##
## Recreate it with `make signing-cert` if the keychain is ever reset.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null \
             | grep "Murmur Local Signing" | head -1 | sed -E 's/.*"(.*)".*/\1/')
endif
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build app run install clean icon signing-cert

all: app

build:
	swift build -c $(CONFIG) --scratch-path "$(SCRATCH)"

## Regenerates AppIcon.icns from Tools/makeicon.swift. Not a dependency of `app` — the
## icon rarely changes and rendering 10 PNGs on every build is wasted time.
icon:
	@swift Tools/makeicon.swift
	@iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
	@echo "wrote Resources/AppIcon.icns"

## Assemble a real .app bundle. TCC (microphone + Accessibility) keys on bundle identity
## and code signature, so the raw SwiftPM binary can't be used directly.
app: build
	@rm -rf "$(BUNDLE)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp $(BUILD) "$(CONTENTS)/MacOS/$(EXEC)"
	@cp Resources/Info.plist "$(CONTENTS)/Info.plist"
	@if [ -f Resources/AppIcon.icns ]; then cp Resources/AppIcon.icns "$(CONTENTS)/Resources/"; fi
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@# Belt and braces: the staging dir isn't synced, but the copied binary can still carry
	@# xattrs inherited from the synced .build directory.
	@xattr -cr "$(BUNDLE)"
	@codesign --force --sign "$(SIGN_ID)" \
		--entitlements Resources/$(EXEC).entitlements \
		--options runtime \
		--timestamp=none \
		"$(BUNDLE)"
	@echo "built $(BUNDLE)  [signed: $(SIGN_ID)]"

## Only ever targets the InfoAscentMurmure executable — never the separate `murmur` app.
run: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@open "$(BUNDLE)"

## Ad-hoc signatures change on every rebuild, which resets the Accessibility grant.
## Installing to /Applications keeps the path stable and makes re-granting a one-click fix.
install: app
	@pkill -x $(EXEC) 2>/dev/null || true
	@# $(BUNDLE) is an absolute staging path — the destination must use $(APPNAME) alone.
	@rm -rf "/Applications/$(APPNAME)"
	@cp -R "$(BUNDLE)" "/Applications/$(APPNAME)"
	@open "/Applications/$(APPNAME)"
	@echo "installed to /Applications/$(APPNAME)"

## Regenerates the local code-signing certificate. Only needed once per machine, or after
## a keychain reset. Harmless to re-run: it replaces the identity of the same name.
signing-cert:
	@tmp=$$(mktemp -d); \
	openssl req -x509 -newkey rsa:2048 -keyout $$tmp/key.pem -out $$tmp/cert.pem \
		-days 3650 -nodes -subj "/CN=Murmur Local Signing" \
		-addext "basicConstraints=critical,CA:false" \
		-addext "keyUsage=critical,digitalSignature" \
		-addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null; \
	openssl pkcs12 -export -out $$tmp/cert.p12 -inkey $$tmp/key.pem -in $$tmp/cert.pem \
		-name "Murmur Local Signing" \
		-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
		-passout pass:murmur 2>/dev/null; \
	security import $$tmp/cert.p12 -k $$HOME/Library/Keychains/login.keychain-db -P murmur -A; \
	rm -rf $$tmp
	@security find-identity -v -p codesigning | grep "Murmur Local Signing"

clean:
	@rm -rf .build "$(STAGE)" "$(SCRATCH)"
