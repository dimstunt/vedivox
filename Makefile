APP_NAME    := Vedivox
# The command's name, in one place with VedivoxMCP/Package.swift's `cliName`: the
# binaries are $(CLI_NAME) and $(CLI_NAME)-mcp.
CLI_NAME    := vedivox
MCP_NAME    := $(CLI_NAME)-mcp
APP_DIR     := Vedivox
MCP_DIR     := VedivoxMCP
BUILD_DIR   := $(APP_DIR)/build
INSTALL_DIR := /Applications
MCP_BIN     := $(HOME)/.local/bin
# Falls back to 1 in a source archive without git history.
BUILD_NUMBER := $(shell git rev-list --count HEAD 2>/dev/null || echo 1)

LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# One derivedData per checkout: parallel `make test` from several worktrees
# sharing one folder hit "database is locked" or tested another tree's build.
# A hash of the path, not its name — worktree names can be Cyrillic.
CHECKOUT_ID := $(shell printf '%s' '$(CURDIR)' | shasum | cut -c1-8)
TEST_DERIVED := $(HOME)/Library/Caches/vedivox-precommit-build-$(CHECKOUT_ID)
SMOKE_DERIVED := $(HOME)/Library/Caches/vedivox-smoke-build-$(CHECKOUT_ID)
SNAPSHOT_DERIVED := $(HOME)/Library/Caches/vedivox-snapshot-build-$(CHECKOUT_ID)

# Signing. project.yml carries the author's Apple Development team; anyone else
# overrides it per call: `make install TEAM=ABCDE12345` (your own team) or
# `TEAM=-` (ad-hoc, no Apple account — macOS then asks for the privacy
# permissions again after every rebuild, because the signature changes).
# Without TEAM and without a certificate of the author's team in the keychain
# the build signs ad hoc on its own, so `make test` works on a fresh machine.
AUTHOR_TEAM := $(shell sed -n 's/^    DEVELOPMENT_TEAM: *//p' $(APP_DIR)/project.yml)
ifeq ($(TEAM),)
ifeq ($(shell security find-certificate -a -c "Apple Development" 2>/dev/null | grep -c $(AUTHOR_TEAM)),0)
TEAM := -
$(info ⚠  no Apple Development certificate of team $(AUTHOR_TEAM) — signing ad hoc (TEAM=-); pass TEAM=<your team ID> to sign with yours)
endif
endif
ifeq ($(TEAM),-)
SIGN_FLAGS := CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
else ifneq ($(TEAM),)
SIGN_FLAGS := DEVELOPMENT_TEAM=$(TEAM)
endif

# Fails with a hint instead of "command not found" deep inside a recipe.
XCODEGEN = command -v xcodegen >/dev/null || { echo "✗ xcodegen is missing — brew install xcodegen"; exit 1; }; xcodegen

.PHONY: all app mcp install install-app install-mcp clean clean-stale open bench test test-mcp test-ui test-snapshots test-smoke screencast-frames screencast generate unregister-builds dist dist-stage dist-notarized cask

# The default goal only builds. It used to install, and `make -p | grep VAR`
# (which runs the default goal while printing the database) replaced the
# installed app by accident. Installing is `make install`.
all: app mcp

# --- Build ---

app: $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app

$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app: $(shell find $(APP_DIR)/$(APP_DIR) -name '*.swift' -o -name '*.plist' -o -name '*.entitlements' -o -name '*.png') $(APP_DIR)/project.yml docs/GUIDE.md CHANGELOG.md
	cd $(APP_DIR) && $(XCODEGEN) generate
	@mkdir -p $(BUILD_DIR)
	@touch $(BUILD_DIR)/.metadata_never_index
	cd $(APP_DIR) && xcodebuild \
		-project Vedivox.xcodeproj \
		-scheme Vedivox \
		-configuration Release \
		-derivedDataPath build \
		CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) $(SIGN_FLAGS) \
		build

mcp: $(MCP_DIR)/.build/release/$(MCP_NAME)

$(MCP_DIR)/.build/release/$(MCP_NAME): $(shell find $(MCP_DIR)/Sources $(MCP_DIR)/SourcesCLI $(MCP_DIR)/SourcesVedivoxMain $(MCP_DIR)/SourcesMCPMain -name '*.swift') $(MCP_DIR)/Package.swift
	cd $(MCP_DIR) && swift build -c release

# --- Distribution ---

# Unsigned-friendly zip for handing the app to another Mac: Vedivox.app + vedivox CLI
# + INSTALL.md (written for the recipient's Claude Code). ditto keeps the
# bundle signature and resource forks intact; the zip lands in the repo root.
DIST_VERSION := $(shell sed -n 's/.*MARKETING_VERSION: "\(.*\)".*/\1/p' $(APP_DIR)/project.yml)
DIST_NAME    := $(APP_NAME)-$(DIST_VERSION)

dist-stage: app mcp
	@rm -rf $(BUILD_DIR)/dist $(DIST_NAME).zip
	@mkdir -p $(BUILD_DIR)/dist/$(DIST_NAME)
	ditto $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app $(BUILD_DIR)/dist/$(DIST_NAME)/$(APP_NAME).app
	cp docs/INSTALL.md $(BUILD_DIR)/dist/$(DIST_NAME)/INSTALL.md
	cp docs/GUIDE.md $(BUILD_DIR)/dist/$(DIST_NAME)/GUIDE.md
	cp CHANGELOG.md $(BUILD_DIR)/dist/$(DIST_NAME)/CHANGELOG.md
	cp LICENSE $(BUILD_DIR)/dist/$(DIST_NAME)/LICENSE
	cp THIRD_PARTY_NOTICES.md $(BUILD_DIR)/dist/$(DIST_NAME)/THIRD_PARTY_NOTICES.md
	sed 's|@@GITHUB_REPO@@|$(GITHUB_REPO)|g' scripts/install.sh > $(BUILD_DIR)/dist/$(DIST_NAME)/install.sh
	cp scripts/cli_alias.sh $(BUILD_DIR)/dist/$(DIST_NAME)/cli_alias.sh
	mkdir -p $(BUILD_DIR)/dist/$(DIST_NAME)/skills
	cp -R skills/vedivox $(BUILD_DIR)/dist/$(DIST_NAME)/skills/vedivox
	cp -R skills/vedivox-live $(BUILD_DIR)/dist/$(DIST_NAME)/skills/vedivox-live
	cp -R skills/vedivox-enrich $(BUILD_DIR)/dist/$(DIST_NAME)/skills/vedivox-enrich
	cp $(MCP_DIR)/.build/release/$(CLI_NAME) $(BUILD_DIR)/dist/$(DIST_NAME)/$(CLI_NAME)
	codesign -s - --force $(BUILD_DIR)/dist/$(DIST_NAME)/$(CLI_NAME)
	cp $(MCP_DIR)/.build/release/$(MCP_NAME) $(BUILD_DIR)/dist/$(DIST_NAME)/$(MCP_NAME)
	codesign -s - --force $(BUILD_DIR)/dist/$(DIST_NAME)/$(MCP_NAME)

DIST_ZIP = ditto -c -k --norsrc --noextattr --noacl --keepParent $(BUILD_DIR)/dist/$(DIST_NAME) $(DIST_NAME).zip

dist: dist-stage
	$(DIST_ZIP)
	@rm -rf $(BUILD_DIR)/dist
	@echo "✓ $(DIST_NAME).zip"

# The same zip, signed with a Developer ID and notarized, so Gatekeeper opens it
# without the quarantine workaround. Needs a "Developer ID Application"
# certificate and a notarytool keychain profile, created once:
#   xcrun notarytool store-credentials vedivox-notary --apple-id … --team-id … --password …
#   make dist-notarized DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
# The first zip is what Apple scans; the ticket is then stapled into Vedivox.app
# (a bare binary cannot be stapled — `vedivox` is checked online) and the folder is
# zipped again.
NOTARY_PROFILE ?= vedivox-notary
DIST_SIGN = codesign --force --options runtime --timestamp -s "$(DEVELOPER_ID)"

dist-notarized: dist-stage
	@test -n "$(DEVELOPER_ID)" || { echo '✗ DEVELOPER_ID is empty — pass DEVELOPER_ID="Developer ID Application: Name (TEAMID)"'; exit 1; }
	$(DIST_SIGN) --entitlements $(APP_DIR)/$(APP_DIR)/$(APP_DIR).entitlements $(BUILD_DIR)/dist/$(DIST_NAME)/$(APP_NAME).app
	$(DIST_SIGN) $(BUILD_DIR)/dist/$(DIST_NAME)/$(CLI_NAME)
	$(DIST_SIGN) $(BUILD_DIR)/dist/$(DIST_NAME)/$(MCP_NAME)
	$(DIST_ZIP)
	xcrun notarytool submit $(DIST_NAME).zip --keychain-profile $(NOTARY_PROFILE) --wait
	xcrun stapler staple $(BUILD_DIR)/dist/$(DIST_NAME)/$(APP_NAME).app
	@rm -f $(DIST_NAME).zip
	$(DIST_ZIP)
	@rm -rf $(BUILD_DIR)/dist
	@echo "✓ $(DIST_NAME).zip (notarized)"

# --- Homebrew ---

# The public names, each in one place: the repository (owner/name) and the cask
# token. The app's copies are VedivoxLinks.repo and VedivoxLinks.caskToken; change both.
GITHUB_REPO ?= dimstunt/vedivox
CASK_TOKEN  ?= vedivox
CASK_OUT    := build/$(CASK_TOKEN).rb
CASK_CHECK  := $(BUILD_DIR)/cask-check

# Renders the cask for the zip already built by `make dist-notarized` (or
# `make dist`) into $(CASK_OUT), for the $(GITHUB_REPO) owner's homebrew-tap.
# Without a stapled ticket the caveats tell how to get past Gatekeeper.
# `brew style` and `brew audit` take only a tapped cask, so they run in the tap,
# after the file is copied into its Casks/. Never installs anything.
cask:
	@test -f $(DIST_NAME).zip || { echo "✗ $(DIST_NAME).zip is missing — run make dist-notarized first"; exit 1; }
	@mkdir -p $(dir $(CASK_OUT))
	@rm -rf $(CASK_CHECK) && ditto -x -k $(DIST_NAME).zip $(CASK_CHECK)
	@test -d $(CASK_CHECK)/$(DIST_NAME)/$(APP_NAME).app || { echo "✗ $(DIST_NAME).zip has no $(DIST_NAME)/$(APP_NAME).app"; exit 1; }
	@if xcrun stapler validate -q $(CASK_CHECK)/$(DIST_NAME)/$(APP_NAME).app >/dev/null 2>&1; then q=""; else \
		q="This build is not notarized, so macOS refuses to open it. Once, after installing:\n    System Settings → Privacy & Security → Open Anyway, or\n    xattr -dr com.apple.quarantine /Applications/Vedivox.app"; fi; \
	rm -rf $(CASK_CHECK); \
	VERSION=$(DIST_VERSION) SHA=$$(shasum -a 256 $(DIST_NAME).zip | cut -d' ' -f1) REPO=$(GITHUB_REPO) TOKEN=$(CASK_TOKEN) Q="$$q" \
	perl -0pe 's/\@\@VERSION\@\@/$$ENV{VERSION}/g; s/\@\@SHA256\@\@/$$ENV{SHA}/g; s/\@\@REPO\@\@/$$ENV{REPO}/g; \
		s/\@\@TOKEN\@\@/$$ENV{TOKEN}/g; \
		if ($$ENV{Q}) { (my $$q = $$ENV{Q}) =~ s/\\n/\n/g; s/\@\@QUARANTINE_CAVEAT\@\@/$$q/ } else { s/\n\n *\@\@QUARANTINE_CAVEAT\@\@// }' \
		packaging/homebrew/vedivox.rb.template > $(CASK_OUT)
	@echo "✓ $(CASK_OUT) ($(DIST_NAME).zip)"
	@echo "  check it in the tap (brew takes casks by name, not path): copy it to Casks/ there, then brew style and brew audit --cask --strict --online <owner>/tap/$(CASK_TOKEN)"

# --- Install ---

install: install-app install-mcp

# Developer ID: `make install DEVELOPER_ID="Developer ID Application: Name (TEAMID)"`
# signs the installed app and both commands the way dist-notarized does, without
# notarizing. Unlike Apple Development, that signature stays the same from one
# build to the next, so macOS keeps the privacy permissions across installs.
# Without DEVELOPER_ID, as before: the build's own signature, commands ad hoc.
# No DEVELOPER_ID given: the one in the keychain, if there is one. An install
# signed with anything else makes macOS drop the Accessibility and other
# permissions of the installed app, and a dictation in progress is lost.
ifndef DEVELOPER_ID
DEVELOPER_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
endif
BIN_SIGN = $(if $(DEVELOPER_ID),$(DIST_SIGN),codesign -s - --force)

install-app: app unregister-builds
	@if [ -z "$(DEVELOPER_ID)" ] && codesign -dvv $(INSTALL_DIR)/$(APP_NAME).app 2>&1 | grep -q '^Authority=Developer ID'; then \
		echo "✗ $(APP_NAME) in $(INSTALL_DIR) is signed with a Developer ID and this build would not be: macOS would drop its permissions. Pass DEVELOPER_ID=… or run where the keychain is reachable (a sandbox hides it)."; exit 1; fi
	@rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R $(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app $(INSTALL_DIR)/
	$(if $(DEVELOPER_ID),$(DIST_SIGN) --entitlements $(APP_DIR)/$(APP_DIR)/$(APP_DIR).entitlements $(INSTALL_DIR)/$(APP_NAME).app)
	$(if $(DEVELOPER_ID),codesign --verify --strict $(INSTALL_DIR)/$(APP_NAME).app && codesign -dvv $(INSTALL_DIR)/$(APP_NAME).app 2>&1 | grep '^Authority=Developer ID')
	@echo "✓ $(APP_NAME).app → $(INSTALL_DIR)/"

# Drop build copies from the URL-scheme handler registry.
#
# Eleven copies were registered on 2026-08-14, and the system's pick changed
# after every rebuild — which is how a reprocess request reached a build
# directory instead of the running app. Correctness no longer depends on this
# (commands go to the data directory's socket), so this only lowers the noise
# and keeps `open vedivox://` on the installed app when nothing is running.
#
# Unregisters unconditionally, without checking the path exists: an entry whose
# build directory was deleted is still in the registry and still eligible to be
# chosen — five of the eleven entries found on 2026-08-14 were exactly that.
#
# NEVER unregisters $(INSTALL_DIR)/$(APP_NAME).app: that is the copy that has
# to stay reachable. Entries left by Xcode's own DerivedData are outside this
# list; clearing those takes a registry rebuild, which is too heavy to run on
# every install.
unregister-builds:
	@for path in \
		"$(CURDIR)/$(BUILD_DIR)/Build/Products/Debug/$(APP_NAME).app" \
		"$(CURDIR)/$(BUILD_DIR)/Build/Products/Release/$(APP_NAME).app" \
		"$(SMOKE_DERIVED)/Build/Products/Debug/$(APP_NAME).app"; do \
		$(LSREGISTER) -u "$$path" >/dev/null 2>&1 || true; \
	done
	@echo "✓ build copies unregistered from LaunchServices"

install-mcp: mcp
	@mkdir -p $(MCP_BIN)
	cp $(MCP_DIR)/.build/release/$(MCP_NAME) $(MCP_BIN)/$(MCP_NAME)
	$(BIN_SIGN) $(MCP_BIN)/$(MCP_NAME)
	@echo "✓ $(MCP_NAME) → $(MCP_BIN)/"
	cp $(MCP_DIR)/.build/release/$(CLI_NAME) $(MCP_BIN)/$(CLI_NAME)
	$(BIN_SIGN) $(MCP_BIN)/$(CLI_NAME)
	@echo "✓ $(CLI_NAME) → $(MCP_BIN)/"
	@sh scripts/cli_alias.sh $(MCP_BIN) $(CLI_NAME) vox # rename:keep
	@sh scripts/cli_alias.sh $(MCP_BIN) $(MCP_NAME) vox-mcp # rename:keep
	@case ":$$PATH:" in *":$(MCP_BIN):"*) ;; *) echo "⚠  $(MCP_BIN) is not in PATH — add: export PATH=\"$(MCP_BIN):\$$PATH\"" ;; esac

# --- Utilities ---

generate:
	cd $(APP_DIR) && $(XCODEGEN) generate

# Headless logic suite (VedivoxCoreTests) — same gate as .githooks/pre-commit.
# derivedData lives OUTSIDE the repo: ~/Documents is TCC-protected and xctest
# bundles built there fail to load under non-interactive runs.
# A fresh VEDIVOX_DATA_DIR per run: the code under test logs and stores there, never
# in ~/Library/Application Support, and a VEDIVOX_DATA_DIR of the user's own loses.
test: generate
	@mkdir -p $(TEST_DERIVED)
	@touch $(TEST_DERIVED)/.metadata_never_index
	cd $(APP_DIR) && TEST_RUNNER_VEDIVOX_DATA_DIR=$$(mktemp -d -t vedivox-test) xcodebuild test \
		-project Vedivox.xcodeproj -scheme VedivoxCoreTests \
		-destination 'platform=macOS' -derivedDataPath $(TEST_DERIVED) $(SIGN_FLAGS) -quiet

# CLI and MCP package tests (VedivoxMCP/Tests). In-memory databases and a stubbed
# app: the suite refuses to talk to the live command socket, so it is safe next
# to a running Vedivox. Second half of the pre-commit gate (VedivoxMCP changes).
test-mcp:
	cd $(MCP_DIR) && swift test

# Snapshot + app-hosted tests (VedivoxTests). Not part of `make test`: they need the
# app built as a test host, so they cost a full app build. Reference images live
# in Vedivox/VedivoxTests/__Snapshots__ — a failure writes the actual image next to the
# reference for comparison.
test-ui: generate
	cd $(APP_DIR) && xcodebuild test \
		-project Vedivox.xcodeproj -scheme Vedivox \
		-destination 'platform=macOS' -derivedDataPath build \
		-only-testing:VedivoxTests $(SIGN_FLAGS) -quiet

# Offscreen snapshots of the main screens in every palette × theme
# (VedivoxSnapshotTests). Unhosted: no app process, no window, no
# activation, the xctest tool's defaults and a throwaway data directory — safe
# to run while Vedivox is in use: each run gets a fresh VEDIVOX_DATA_DIR under $$TMPDIR.
# References live in Vedivox/VedivoxSnapshotTests/__Snapshots__; RECORD=1 re-records them
# (the run then reports failures by design). scripts/snapshot_sheet.py lays them
# out on one contact sheet. Run explicitly, not a gate. A failed variant's
# actual image lands in $(SNAPSHOT_DERIVED)/failures, emptied every run (the
# library default, $$TMPDIR/ScreenSnapshotTests, mixes every worktree's runs).
# SNAPSHOT_DIR=<dir> reads and records the references there instead, e.g. one
# folder per design variant (`make test-snapshots RECORD=1 SNAPSHOT_DIR=/tmp/a`).
test-snapshots: generate
	@mkdir -p $(SNAPSHOT_DERIVED)
	@touch $(SNAPSHOT_DERIVED)/.metadata_never_index
	@rm -rf $(SNAPSHOT_DERIVED)/failures
	cd $(APP_DIR) && TEST_RUNNER_VEDIVOX_DATA_DIR=$$(mktemp -d -t vedivox-snapshots) \
		TEST_RUNNER_SNAPSHOT_ARTIFACTS=$(SNAPSHOT_DERIVED)/failures \
		TEST_RUNNER_VEDIVOX_SNAPSHOT_RECORD=$(RECORD) TEST_RUNNER_VEDIVOX_SNAPSHOT_DIR=$(SNAPSHOT_DIR) xcodebuild test \
		-project Vedivox.xcodeproj -scheme VedivoxSnapshotTests \
		-destination 'platform=macOS' -derivedDataPath $(SNAPSHOT_DERIVED) $(SIGN_FLAGS) -quiet

# Screencast, run explicitly. screencast-frames draws the screens of
# test-snapshots as sequences (live text arriving, the playhead moving, the
# dictation HUD filling) and writes PNGs to $(SCREENCAST_FRAMES); same isolation
# as test-snapshots, safe while Vedivox is in use. screencast renders the film
# and the landing loops from those frames with headless Chrome and ffmpeg into
# $(SCREENCAST_OUT) (scripts/screencast/render.py; ONLY=<name> renders one).
SCREENCAST_FRAMES ?= $(HOME)/Library/Caches/vedivox-screencast-frames
SCREENCAST_OUT ?= $(HOME)/Library/Caches/vedivox-screencast
screencast-frames: generate
	@mkdir -p $(SNAPSHOT_DERIVED) $(SCREENCAST_FRAMES)
	@touch $(SNAPSHOT_DERIVED)/.metadata_never_index
	cd $(APP_DIR) && TEST_RUNNER_VEDIVOX_DATA_DIR=$$(mktemp -d -t vedivox-snapshots) \
		TEST_RUNNER_VEDIVOX_SCREENCAST_DIR=$(SCREENCAST_FRAMES) xcodebuild test \
		-project Vedivox.xcodeproj -scheme VedivoxSnapshotTests \
		-only-testing:VedivoxSnapshotTests/ScreenSnapshotTests/testScreencastFrames \
		-destination 'platform=macOS' -derivedDataPath $(SNAPSHOT_DERIVED) $(SIGN_FLAGS) -quiet

screencast:
	uv run scripts/screencast/render.py --frames $(SCREENCAST_FRAMES) --out $(SCREENCAST_OUT) $(if $(ONLY),--only $(ONLY))

# Smoke UI tests (VedivoxUITests, XCUITest) over the main window paths. Each test
# runs the Debug app on a throwaway seeded data directory (VEDIVOX_DATA_DIR), never
# the live one. Two things are still shared with the installed app, so:
# - it refuses while Vedivox is running: XCUIApplication terminates any running
#   copy of the bundle id, and that could be a recording. Quit Vedivox first
#   (`vedivox status` says idle), relaunch it after;
# - the app writes UserDefaults (window frame and the like) into the same
#   com.dimstunt.Vedivox domain, so the domain is exported before and put back after.
# Needs Accessibility for the test runner (the first run may ask).
SMOKE_DEFAULTS := $(SMOKE_DERIVED)/defaults-backup.plist
test-smoke: generate
	@if pgrep -x $(APP_NAME) >/dev/null; then echo "✗ $(APP_NAME) is running — quit it first (check \`vedivox status\` is idle)"; exit 1; fi
	@mkdir -p $(SMOKE_DERIVED)
	@touch $(SMOKE_DERIVED)/.metadata_never_index
	defaults export com.dimstunt.Vedivox $(SMOKE_DEFAULTS)
	cd $(APP_DIR) && xcodebuild test \
		-project Vedivox.xcodeproj -scheme VedivoxUITests \
		-destination 'platform=macOS' -derivedDataPath $(SMOKE_DERIVED) $(SIGN_FLAGS) -quiet; \
		status=$$?; \
		test -s $(SMOKE_DEFAULTS) && defaults delete com.dimstunt.Vedivox && defaults import com.dimstunt.Vedivox $(SMOKE_DEFAULTS); \
		$(LSREGISTER) -u "$(SMOKE_DERIVED)/Build/Products/Debug/$(APP_NAME).app" >/dev/null 2>&1; \
		exit $$status

# Deterministic diarization bench (both modes), deterministic
# hashing pins the Swift dictionary iteration order in FluidAudio's
# SpeakerManager — the run-to-run nondeterminism source. See
# the private fixtures for the acceptance gate.
bench:
	cd $(APP_DIR) && $(XCODEGEN) generate
	cd $(APP_DIR) && TEST_RUNNER_SWIFT_DETERMINISTIC_HASHING=1 xcodebuild test \
		-project Vedivox.xcodeproj -scheme VedivoxBench \
		-only-testing:VedivoxBench/ScenarioBenchTests \
		-destination 'platform=macOS' -derivedDataPath build $(SIGN_FLAGS) -quiet

open: install-app
	open $(INSTALL_DIR)/$(APP_NAME).app

# Every cache a build leaves behind (~8 GB measured 2026-08-28): Release
# derivedData, test derivedData, SwiftPM builds, and the ANE compilation cache
# (each rebuilt binary leaves a stale Parakeet specialization in it).
ANE_CACHE := $(HOME)/Library/Caches/com.dimstunt.Vedivox/com.apple.e5rt.e5bundlecache
clean:
	rm -rf $(BUILD_DIR) $(TEST_DERIVED) $(SNAPSHOT_DERIVED) $(MCP_DIR)/.build transcribe-bench/.build $(ANE_CACHE)
	@echo "✓ Clean — next make install / make test rebuild from scratch (minutes); first launch recompiles Parakeet for the ANE (~30 s)"

# Test build folders of worktrees that no longer exist (~2 GB each, nothing
# else removes them), plus the shared pre-hash folders. Keeps every folder whose
# hash matches a live `git worktree list` path. STALE_RM=echo for a dry run.
# Builds made before the internal rename sit under the old names; a branch that
# has not merged it yet still writes there.
STALE_RM ?= rm -rf
OLD_CACHES := vox-precommit-build vox-snapshot-build vox-smoke-build # rename:keep
clean-stale:
	@live=$$(git worktree list --porcelain | sed -n 's/^worktree //p' | while IFS= read -r p; do printf '%s' "$$p" | shasum | cut -c1-8; done); \
	for d in $(foreach n,$(OLD_CACHES),$(HOME)/Library/Caches/$(n) $(HOME)/Library/Caches/$(n)-*) \
	         $(HOME)/Library/Caches/vedivox-precommit-build-* $(HOME)/Library/Caches/vedivox-snapshot-build-* $(HOME)/Library/Caches/vedivox-smoke-build-*; do \
		[ -d "$$d" ] || continue; \
		case "$$d" in *-build) ;; *) echo "$$live" | grep -qx "$${d##*-}" && continue ;; esac; \
		$(STALE_RM) "$$d"; echo "removed $$d"; \
	done
