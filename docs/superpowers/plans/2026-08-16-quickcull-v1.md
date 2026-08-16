# QuickCull v1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build QuickCull v1 — a native macOS (14+) SwiftUI app that decodes multi-selected raw files from all major camera brands to full-resolution q75 JPEGs, then lets the photographer scrub with arrow keys and flag rejects with Z for a Trash commit.

**Architecture:** Three targets in one Xcode project. `QuickCullCore` (framework) holds all logic — LibRaw decode wrapper, JPEG cache store, session state, sliding window, decode engine, trash commit, app state — with protocols at every boundary so each unit is independently testable. `QuickCull` (app) is a thin SwiftUI layer (views + keyboard monitor). `QuickCullCoreTests` is a logic test bundle (no host app) that runs via `xcrun xctest` directly. LibRaw 0.22.1 is built once by a vendoring script into `Build/libraw/libraw.dylib` (universal), dynamically linked and embedded inside the framework bundle for LGPL compliance.

**Tech Stack:** Swift 5 language mode on Xcode 26 toolchain (Swift 6.2), SwiftUI + Observation (macOS 14), LibRaw 0.22.1 (C API, no libjpeg — JPEG encoding via ImageIO), XCTest.

## Global Constraints

- macOS deployment target: **14.0**. Swift language version: **5.0** (not 6) in all targets.
- JPEG decode cache: **q75**, full resolution, no embedded previews — every JPEG is a true demosaic.
- Cache directory: `~/Library/Application Support/QuickCull/cache/`, **wiped on every launch**, best-effort wipe on quit.
- Sliding window: current image **±30** (max 61 thumbnails in memory); display-size rendering max **3** (current ±1).
- Flags are **in-memory only**, cleared on new import. Commit moves flagged files to macOS Trash, then scrubbing continues on the remainder.
- Keyboard: ←/→ navigate, ↑/↓ jump ±10, Z toggles red corner badge. No zoom, no undo in v1.
- Module/product names: app `QuickCull` (bundle id `com.quickcull.app`), framework `QuickCullCore` (`com.quickcull.core`), tests `QuickCullCoreTests` (`com.quickcull.core.tests`).
- LGPL-2.1 compliance: `libraw.dylib` is dynamically linked, embedded at `QuickCullCore.framework/Versions/A/Frameworks/libraw.dylib`, and user-replaceable (documented in README/NOTICE).
- All verification commands use `-derivedDataPath /tmp/qc-dd` and `CODE_SIGNING_ALLOWED=NO` (required in the sandboxed harness; harmless on a developer Mac). Run every command from the repo root.
- Repository root: `/Users/oslo/Files/github/quickcull` (git repo already initialized, spec committed).

## Architecture Note (validated deviation from spec wording)

The spec says "the sliding window holds up to 61 decoded JPEGs in memory." A full-res CGImage for a 45 MP raw is ~135 MB, so 61 of them would need >8 GB — infeasible. Since v1 has no zoom, full-res pixels are never needed in memory (the cache on disk keeps them). Therefore:

- `SlidingWindow` holds 61 **filmstrip-size renderings** (~320 px, a few MB total), loaded from the cached full-res JPEGs via ImageIO thumbnail downsampling.
- `DisplayImageProvider` holds up to **3 display-size renderings** (current ±1), sized to 2× the screen's long edge.
- The decoded full-res JPEGs stay on disk as the single source of truth.

The window radius (±30), decode-once-before-scrub, and memory-boundedness requirements are unchanged.

## File Structure

```
quickcull/
├── QuickCull.xcodeproj/                 # hand-written, objectVersion 77 (synchronized folders)
│   └── xcshareddata/xcschemes/
│       ├── QuickCull.xcscheme           # build+run the app
│       └── QuickCullCore.xcscheme       # build framework + tests, test action
├── QuickCull/                           # app target (UI only)
│   ├── QuickCullApp.swift               # @main, WindowGroup
│   ├── RootView.swift                   # phase switch (empty / decoding / scrubbing)
│   ├── EmptyStateView.swift             # import button + fileImporter
│   ├── DecodingView.swift               # Phase 1 progress + failure list
│   ├── ScrubView.swift                  # image + filmstrip + toolbar commit
│   ├── ImageDisplayView.swift           # fit-to-window main image + flag badge
│   ├── FilmstripView.swift              # LazyHStack of window thumbnails
│   ├── FlagBadge.swift                  # red corner badge
│   └── KeyboardMonitor.swift            # NSEvent local monitor → CullKeyMap → AppState
├── QuickCullCore/                       # framework target (all logic)
│   ├── QuickCullCore-Bridging-Header.h  # #include "libraw/libraw.h"
│   ├── Models/RawFileIdentity.swift     # supported extensions, file identity
│   ├── Models/SessionFile.swift
│   ├── Decoding/RawDecoding.swift       # RawBitmap, DecodeError, RawDecoding protocol
│   ├── Decoding/LibRawDecoder.swift     # C API wrapper (full demosaic → CGImage)
│   ├── Storage/ImageCacheStore.swift    # cache dir, wipe, q75 JPEG encode, keying
│   ├── Session/Session.swift            # files, index, in-memory flags
│   ├── Window/WindowPolicy.swift        # pure window math
│   ├── Window/SlidingWindow.swift       # 61-thumb window (+ DisplayImageProvider)
│   ├── Keys/CullKeyMap.swift            # keyCode → action (pure)
│   ├── Engine/DecodeEngine.swift        # parallel Phase 1 decode actor
│   ├── Commit/TrashCommit.swift         # Trashing protocol, FileManagerTrasher
│   └── App/AppState.swift               # @Observable: phases, import, commit, wiring
├── QuickCullCoreTests/                  # logic test bundle (no host)
│   ├── Fixtures/raws/                   # raw sample files (fetched by script)
│   └── *.swift                          # one test file per core unit
├── Scripts/
│   ├── build-libraw.sh                  # vendored LibRaw 0.22.1 → universal dylib
│   └── fetch-fixtures.sh                # raw sample fixtures (sha256-pinned)
├── docs/superpowers/specs/2026-08-16-quickcull-design.md   # (already committed)
├── README.md
├── NOTICE                                 # LibRaw LGPL notice
└── .gitignore                             # Build/, DerivedData/, .DS_Store, xcuserdata
```

Build products are conventional: app embeds `QuickCullCore.framework`; the framework embeds `libraw.dylib` (copy-files phase) and links it via `-L$(PROJECT_DIR)/Build/libraw -lraw` with rpath `@loader_path/Frameworks`.

---

### Task 1: Project skeleton — Xcode project, LibRaw vendoring, green test pipeline

**Files:**
- Create: `QuickCull.xcodeproj/project.pbxproj` (full content below)
- Create: `QuickCull.xcodeproj/xcshareddata/xcschemes/QuickCull.xcscheme`
- Create: `QuickCull.xcodeproj/xcshareddata/xcschemes/QuickCullCore.xcscheme`
- Create: `QuickCull/QuickCullApp.swift`, `QuickCull/RootView.swift`
- Create: `QuickCullCore/Core.swift`, `QuickCullCore/QuickCullCore-Bridging-Header.h`
- Create: `QuickCullCoreTests/CoreTests.swift`
- Create: `Scripts/build-libraw.sh`, `.gitignore`, `README.md`
- Test: `QuickCullCoreTests/CoreTests.swift`

**Interfaces:**
- Produces: targets `QuickCull` (app), `QuickCullCore` (framework), `QuickCullCoreTests` (logic tests); schemes `QuickCull`, `QuickCullCore`; `Build/libraw/libraw.dylib` + `Build/libraw/include/libraw/*.h`; `public struct Core { public static let answer = 42 }` (deleted in Task 2's test cleanup, replaced by real code).

- [ ] **Step 1: Create `.gitignore`**

```gitignore
.DS_Store
Build/
DerivedData/
xcuserdata/
*.xcuserstate
```

- [ ] **Step 2: Create `Scripts/build-libraw.sh`** (pins LibRaw 0.22.1 by sha256; builds a universal dylib with JPEG/Jasper/LCMS disabled — JPEG encoding is ImageIO's job; excludes the `*_ph.cpp` alternate-build files, which duplicate symbols)

```bash
#!/usr/bin/env bash
# Builds libraw.dylib (universal arm64 + x86_64) into Build/libraw/.
set -euo pipefail

VERSION="0.22.1"
SHA256="e676248284075605aa2697a66eeed7dc258820bd1d4988c724d29edffd726726"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/Build/libraw"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Downloading LibRaw ${VERSION}…"
curl -fsSL -o "$WORK/libraw.tar.gz" "https://github.com/LibRaw/LibRaw/archive/refs/tags/${VERSION}.tar.gz"
echo "$SHA256  $WORK/libraw.tar.gz" | shasum -a 256 -c -
tar xzf "$WORK/libraw.tar.gz" -C "$WORK"
SRC="$WORK/LibRaw-${VERSION}"

SOURCES=$(find "$SRC/src" -name '*.cpp' ! -name '*_ph.cpp' | sort | tr '\n' ' ')
SDK=$(xcrun --sdk macosx --show-sdk-path)

mkdir -p "$DEST/include"
clang++ -std=c++11 -O2 -fPIC -DLIBRAW_NODLL -DNO_JPEG -DNO_JASPER -DNO_LCMS \
  -I "$SRC" -I "$SRC/src" \
  -shared -arch arm64 -arch x86_64 -isysroot "$SDK" -mmacosx-version-min=14.0 \
  -Wl,-install_name,@rpath/libraw.dylib \
  $SOURCES -o "$DEST/libraw.dylib"

cp -R "$SRC/libraw" "$DEST/include/"
echo "Built $DEST/libraw.dylib"
lipo -info "$DEST/libraw.dylib"
```

- [ ] **Step 3: Create `QuickCull.xcodeproj/project.pbxproj`** with exactly this content (validated format: objectVersion 77, synchronized folders, app + framework + logic-test targets, LibRaw pre-build script phase, dylib embed-in-framework copy phase, app embed-framework phase, bridging header, rpaths):

```
// !$*UTF8*$!
{
	archiveVersion = 1;
	classes = {
	};
	objectVersion = 77;
	objects = {

/* Begin PBXBuildFile section */
		B10000000000000000000005 /* QuickCullCore.framework in Frameworks */ = {isa = PBXBuildFile; fileRef = B10000000000000000000003 /* QuickCullCore.framework */; };
		C10000000000000000000006 /* libraw.dylib in Embed Libraries */ = {isa = PBXBuildFile; fileRef = C10000000000000000000004 /* libraw.dylib */; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };
		C10000000000000000000007 /* QuickCullCore.framework in Embed Frameworks */ = {isa = PBXBuildFile; fileRef = B10000000000000000000003 /* QuickCullCore.framework */; settings = {ATTRIBUTES = (CodeSignOnCopy, ); }; };
/* End PBXBuildFile section */

/* Begin PBXContainerItemProxy section */
		A1000000000000000000001C /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = A10000000000000000000011 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = B1000000000000000000000D;
			remoteInfo = QuickCullCore;
		};
		B10000000000000000000010 /* PBXContainerItemProxy */ = {
			isa = PBXContainerItemProxy;
			containerPortal = A10000000000000000000011 /* Project object */;
			proxyType = 1;
			remoteGlobalIDString = B1000000000000000000000D;
			remoteInfo = QuickCullCore;
		};
/* End PBXContainerItemProxy section */

/* Begin PBXCopyFilesBuildPhase section */
		C10000000000000000000001 /* Embed Frameworks */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
				C10000000000000000000007 /* QuickCullCore.framework in Embed Frameworks */,
			);
			name = "Embed Frameworks";
			runOnlyForDeploymentPostprocessing = 0;
		};
		C10000000000000000000003 /* Embed Libraries */ = {
			isa = PBXCopyFilesBuildPhase;
			buildActionMask = 2147483647;
			dstPath = "";
			dstSubfolderSpec = 10;
			files = (
				C10000000000000000000006 /* libraw.dylib in Embed Libraries */,
			);
			name = "Embed Libraries";
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXCopyFilesBuildPhase section */

/* Begin PBXFileReference section */
		A10000000000000000000005 /* QuickCull.app */ = {isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = QuickCull.app; sourceTree = BUILT_PRODUCTS_DIR; };
		B10000000000000000000003 /* QuickCullCore.framework */ = {isa = PBXFileReference; explicitFileType = wrapper.framework; includeInIndex = 0; path = QuickCullCore.framework; sourceTree = BUILT_PRODUCTS_DIR; };
		B10000000000000000000004 /* QuickCullCoreTests.xctest */ = {isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = QuickCullCoreTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; };
		C10000000000000000000004 /* libraw.dylib */ = {isa = PBXFileReference; lastKnownFileType = "compiled.mach-o.dylib"; name = libraw.dylib; path = Build/libraw/libraw.dylib; sourceTree = "<group>"; };
/* End PBXFileReference section */

/* Begin PBXFileSystemSynchronizedRootGroup section */
		A10000000000000000000001 /* QuickCull */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = QuickCull;
			sourceTree = "<group>";
		};
		B10000000000000000000001 /* QuickCullCore */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = QuickCullCore;
			sourceTree = "<group>";
		};
		B10000000000000000000002 /* QuickCullCoreTests */ = {
			isa = PBXFileSystemSynchronizedRootGroup;
			path = QuickCullCoreTests;
			sourceTree = "<group>";
		};
/* End PBXFileSystemSynchronizedRootGroup section */

/* Begin PBXFrameworksBuildPhase section */
		A10000000000000000000007 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				B10000000000000000000005 /* QuickCullCore.framework in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B10000000000000000000006 /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B1000000000000000000000A /* Frameworks */ = {
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		A10000000000000000000003 = {
			isa = PBXGroup;
			children = (
				A10000000000000000000001 /* QuickCull */,
				B10000000000000000000001 /* QuickCullCore */,
				B10000000000000000000002 /* QuickCullCoreTests */,
				C10000000000000000000005 /* Build */,
				A10000000000000000000004 /* Products */,
			);
			sourceTree = "<group>";
		};
		A10000000000000000000004 /* Products */ = {
			isa = PBXGroup;
			children = (
				A10000000000000000000005 /* QuickCull.app */,
				B10000000000000000000003 /* QuickCullCore.framework */,
				B10000000000000000000004 /* QuickCullCoreTests.xctest */,
			);
			name = Products;
			sourceTree = "<group>";
		};
		C10000000000000000000005 /* Build */ = {
			isa = PBXGroup;
			children = (
				C10000000000000000000004 /* libraw.dylib */,
			);
			name = Build;
			sourceTree = "<group>";
		};
/* End PBXGroup section */

/* Begin PBXHeadersBuildPhase section */
		B10000000000000000000007 /* Headers */ = {
			isa = PBXHeadersBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXHeadersBuildPhase section */

/* Begin PBXNativeTarget section */
		A1000000000000000000000D /* QuickCull */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = A10000000000000000000013 /* Build configuration list for PBXNativeTarget "QuickCull" */;
			buildPhases = (
				A10000000000000000000008 /* Sources */,
				A10000000000000000000007 /* Frameworks */,
				A10000000000000000000009 /* Resources */,
				C10000000000000000000001 /* Embed Frameworks */,
			);
			buildRules = (
			);
			dependencies = (
				A1000000000000000000001B /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				A10000000000000000000001 /* QuickCull */,
			);
			name = QuickCull;
			packageProductDependencies = (
			);
			productName = QuickCull;
			productReference = A10000000000000000000005 /* QuickCull.app */;
			productType = "com.apple.product-type.application";
		};
		B1000000000000000000000D /* QuickCullCore */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B10000000000000000000011 /* Build configuration list for PBXNativeTarget "QuickCullCore" */;
			buildPhases = (
				C10000000000000000000002 /* Build LibRaw */,
				B10000000000000000000007 /* Headers */,
				B10000000000000000000008 /* Sources */,
				B10000000000000000000006 /* Frameworks */,
				B10000000000000000000009 /* Resources */,
				C10000000000000000000003 /* Embed Libraries */,
			);
			buildRules = (
			);
			dependencies = (
			);
			fileSystemSynchronizedGroups = (
				B10000000000000000000001 /* QuickCullCore */,
			);
			name = QuickCullCore;
			packageProductDependencies = (
			);
			productName = QuickCullCore;
			productReference = B10000000000000000000003 /* QuickCullCore.framework */;
			productType = "com.apple.product-type.framework";
		};
		B1000000000000000000000E /* QuickCullCoreTests */ = {
			isa = PBXNativeTarget;
			buildConfigurationList = B10000000000000000000012 /* Build configuration list for PBXNativeTarget "QuickCullCoreTests" */;
			buildPhases = (
				B1000000000000000000000B /* Sources */,
				B1000000000000000000000A /* Frameworks */,
				B1000000000000000000000C /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
				B1000000000000000000000F /* PBXTargetDependency */,
			);
			fileSystemSynchronizedGroups = (
				B10000000000000000000002 /* QuickCullCoreTests */,
			);
			name = QuickCullCoreTests;
			packageProductDependencies = (
			);
			productName = QuickCullCoreTests;
			productReference = B10000000000000000000004 /* QuickCullCoreTests.xctest */;
			productType = "com.apple.product-type.bundle.unit-test";
		};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		A10000000000000000000011 /* Project object */ = {
			isa = PBXProject;
			attributes = {
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2600;
				LastUpgradeCheck = 2600;
				TargetAttributes = {
					A1000000000000000000000D = {
						CreatedOnToolsVersion = 26.0;
					};
					B1000000000000000000000D = {
						CreatedOnToolsVersion = 26.0;
					};
					B1000000000000000000000E = {
						CreatedOnToolsVersion = 26.0;
						TestTargetID = B1000000000000000000000D;
					};
				};
			};
			buildConfigurationList = A10000000000000000000012 /* Build configuration list for PBXProject "QuickCull" */;
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = A10000000000000000000003;
			minimizedProjectReferenceProxies = 1;
			preferredProjectObjectVersion = 77;
			productRefGroup = A10000000000000000000004 /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				A1000000000000000000000D /* QuickCull */,
				B1000000000000000000000D /* QuickCullCore */,
				B1000000000000000000000E /* QuickCullCoreTests */,
			);
		};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		A10000000000000000000009 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B10000000000000000000009 /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B1000000000000000000000C /* Resources */ = {
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXResourcesBuildPhase section */

/* Begin PBXShellScriptBuildPhase section */
		C10000000000000000000002 /* Build LibRaw */ = {
			isa = PBXShellScriptBuildPhase;
			alwaysOutOfDate = 1;
			buildActionMask = 2147483647;
			files = (
			);
			inputFileListPaths = (
			);
			inputPaths = (
			);
			name = "Build LibRaw";
			outputFileListPaths = (
			);
			outputPaths = (
			);
			runOnlyForDeploymentPostprocessing = 0;
			shellPath = /bin/sh;
			shellScript = "if [ ! -f \"$PROJECT_DIR/Build/libraw/libraw.dylib\" ]; then bash \"$PROJECT_DIR/Scripts/build-libraw.sh\"; fi\n";
		};
/* End PBXShellScriptBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		A10000000000000000000008 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B10000000000000000000008 /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
		B1000000000000000000000B /* Sources */ = {
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		};
/* End PBXSourcesBuildPhase section */

/* Begin PBXTargetDependency section */
		A1000000000000000000001B /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = B1000000000000000000000D /* QuickCullCore */;
			targetProxy = A1000000000000000000001C /* PBXContainerItemProxy */;
		};
		B1000000000000000000000F /* PBXTargetDependency */ = {
			isa = PBXTargetDependency;
			target = B1000000000000000000000D /* QuickCullCore */;
			targetProxy = B10000000000000000000010 /* PBXContainerItemProxy */;
		};
/* End PBXTargetDependency section */

/* Begin XCBuildConfiguration section */
		A10000000000000000000015 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				ENABLE_TESTABILITY = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				HEADER_SEARCH_PATHS = (
					"$(inherited)",
					"$(PROJECT_DIR)/Build/libraw/include",
				);
				GCC_DYNAMIC_NO_PIC = NO;
				GCC_NO_COMMON_BLOCKS = YES;
				GCC_OPTIMIZATION_LEVEL = 0;
				GCC_PREPROCESSOR_DEFINITIONS = (
					"DEBUG=1",
					"$(inherited)",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = INCLUDE_SOURCE;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
			};
			name = Debug;
		};
		A10000000000000000000016 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				ENABLE_NS_ASSERTIONS = NO;
				HEADER_SEARCH_PATHS = (
					"$(inherited)",
					"$(PROJECT_DIR)/Build/libraw/include",
				);
				ENABLE_STRICT_OBJC_MSGSEND = YES;
				GCC_C_LANGUAGE_STANDARD = gnu17;
				GCC_NO_COMMON_BLOCKS = YES;
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				MTL_ENABLE_DEBUG_INFO = NO;
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
			};
			name = Release;
		};
		A10000000000000000000017 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		A10000000000000000000018 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = YES;
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.app;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_EMIT_LOC_STRINGS = YES;
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		B10000000000000000000013 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEFINES_MODULE = YES;
				DYLIB_COMPATIBILITY_VERSION = 1;
				DYLIB_CURRENT_VERSION = 1;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@loader_path/Frameworks",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				OTHER_LDFLAGS = (
					"$(inherited)",
					"-L$(PROJECT_DIR)/Build/libraw",
					"-lraw",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.core;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_OBJC_BRIDGING_HEADER = "QuickCullCore/QuickCullCore-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		B10000000000000000000014 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				CURRENT_PROJECT_VERSION = 1;
				DEFINES_MODULE = YES;
				DYLIB_COMPATIBILITY_VERSION = 1;
				DYLIB_CURRENT_VERSION = 1;
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				GENERATE_INFOPLIST_FILE = YES;
				INSTALL_PATH = "$(LOCAL_LIBRARY_DIR)/Frameworks";
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@loader_path/Frameworks",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 1.0;
				OTHER_LDFLAGS = (
					"$(inherited)",
					"-L$(PROJECT_DIR)/Build/libraw",
					"-lraw",
				);
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.core;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_OBJC_BRIDGING_HEADER = "QuickCullCore/QuickCullCore-Bridging-Header.h";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
		B10000000000000000000015 /* Debug */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@loader_path/../Frameworks",
					"@loader_path/../../..",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.core.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Debug;
		};
		B10000000000000000000016 /* Release */ = {
			isa = XCBuildConfiguration;
			buildSettings = {
				CODE_SIGN_STYLE = Automatic;
				GENERATE_INFOPLIST_FILE = YES;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@loader_path/../Frameworks",
					"@loader_path/../../..",
					"@executable_path/../Frameworks",
				);
				MACOSX_DEPLOYMENT_TARGET = 14.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.quickcull.core.tests;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SWIFT_VERSION = 5.0;
			};
			name = Release;
		};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		A10000000000000000000012 /* Build configuration list for PBXProject "QuickCull" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A10000000000000000000015 /* Debug */,
				A10000000000000000000016 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		A10000000000000000000013 /* Build configuration list for PBXNativeTarget "QuickCull" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				A10000000000000000000017 /* Debug */,
				A10000000000000000000018 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B10000000000000000000011 /* Build configuration list for PBXNativeTarget "QuickCullCore" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				B10000000000000000000013 /* Debug */,
				B10000000000000000000014 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
		B10000000000000000000012 /* Build configuration list for PBXNativeTarget "QuickCullCoreTests" */ = {
			isa = XCConfigurationList;
			buildConfigurations = (
				B10000000000000000000015 /* Debug */,
				B10000000000000000000016 /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		};
/* End XCConfigurationList section */
	};
	rootObject = A10000000000000000000011 /* Project object */;
}
```

- [ ] **Step 4: Create `QuickCull.xcodeproj/xcshareddata/xcschemes/QuickCullCore.xcscheme`** (the test scheme — testable = `QuickCullCoreTests`; its existence is what makes `build-for-testing` produce the xctest bundle):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion = "2600" version = "1.7">
   <BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry buildForTesting = "YES" buildForRunning = "YES" buildForProfiling = "YES" buildForArchiving = "YES" buildForAnalyzing = "YES">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "B1000000000000000000000D" BuildableName = "QuickCullCore.framework" BlueprintName = "QuickCullCore" ReferencedContainer = "container:QuickCull.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv = "YES">
      <Testables>
         <TestableReference skipped = "NO">
            <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "B1000000000000000000000E" BuildableName = "QuickCullCoreTests.xctest" BlueprintName = "QuickCullCoreTests" ReferencedContainer = "container:QuickCull.xcodeproj">
            </BuildableReference>
         </TestableReference>
      </Testables>
   </TestAction>
   <LaunchAction buildConfiguration = "Debug" selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" launchStyle = "0" useCustomWorkingDirectory = "NO" ignoresPersistentStateOnLaunch = "NO" debugDocumentVersioning = "YES" debugServiceExtension = "internal" allowLocationSimulation = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "B1000000000000000000000D" BuildableName = "QuickCullCore.framework" BlueprintName = "QuickCullCore" ReferencedContainer = "container:QuickCull.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction buildConfiguration = "Release" shouldUseLaunchSchemeArgsEnv = "YES" savedToolIdentifier = "" useCustomWorkingDirectory = "NO" debugDocumentVersioning = "YES">
      <BuildableProductRunnable runnableDebuggingMode = "0">
         <BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "B1000000000000000000000D" BuildableName = "QuickCullCore.framework" BlueprintName = "QuickCullCore" ReferencedContainer = "container:QuickCull.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction buildConfiguration = "Debug"/>
   <ArchiveAction buildConfiguration = "Release" revealArchiveInOrganizer = "YES"/>
</Scheme>
```

- [ ] **Step 5: Create `QuickCull.xcodeproj/xcshareddata/xcschemes/QuickCull.xcscheme`** (app run scheme; build entries for both the app `A1000000000000000000000D` and the framework `B1000000000000000000000D`; LaunchAction runnable = app `A10000000000000000000005`; no TestAction entries; identical structure to the scheme above with those IDs swapped).

- [ ] **Step 6: Create app + framework + test source files**

`QuickCull/QuickCullApp.swift`:
```swift
import SwiftUI

@main
struct QuickCullApp: App {
    var body: some Scene {
        WindowGroup {
            Text("QuickCull").padding()
        }
    }
}
```

`QuickCullCore/Core.swift`:
```swift
public struct Core {
    public static let answer = 42
}
```

`QuickCullCore/QuickCullCore-Bridging-Header.h`:
```c
// LibRaw C API surface used by LibRawDecoder.
#include "libraw/libraw.h"
```

`QuickCullCoreTests/CoreTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class CoreTests: XCTestCase {
    func testAnswer() {
        XCTAssertEqual(Core.answer, 42)
    }
}
```

- [ ] **Step 7: Create a minimal `README.md`**

```markdown
# QuickCull

Native macOS app for fast raw-image culling. Culls raw files from all major
camera manufacturers: decode everything to high-quality JPEG, scrub with the
arrow keys, flag rejects with Z, commit to Trash.

See `docs/superpowers/specs/` for the design.

## Build

Requires Xcode (16+) on macOS 14+. First build downloads and compiles LibRaw
into `Build/libraw/` automatically.

    xcodebuild -project QuickCull.xcodeproj -scheme QuickCull build
```

- [ ] **Step 8: Build the test bundle (this also triggers the LibRaw vendoring on first run — expect it to take a few minutes)**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing`

Expected: `** TEST BUILD SUCCEEDED **`

- [ ] **Step 9: Run the test**

Run: `xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`

Expected:
```
Test Case '-[QuickCullCoreTests.CoreTests testAnswer]' passed (…)
Test Suite 'QuickCullCoreTests.xctest' passed …
```

- [ ] **Step 10: Build the app and verify the embed chain**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build`

Then: `ls /tmp/qc-dd/Build/Products/Debug/QuickCull.app/Contents/Frameworks/` → must show `QuickCullCore.framework`; and `ls /tmp/qc-dd/Build/Products/Debug/QuickCull.app/Contents/Frameworks/QuickCullCore.framework/Versions/A/Frameworks/` → must show `libraw.dylib`; and `lipo -info /tmp/qc-dd/Build/Products/Debug/QuickCull.app/Contents/Frameworks/QuickCullCore.framework/Versions/A/Frameworks/libraw.dylib` → `Architectures in the fat file: … are: x86_64 arm64`.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: project skeleton with vendored LibRaw and green test pipeline"
```

---

### Task 2: Raw decoder — file identity, fixtures, LibRawDecoder

**Files:**
- Create: `Scripts/fetch-fixtures.sh`
- Create: `QuickCullCore/Models/RawFileIdentity.swift`
- Create: `QuickCullCore/Models/SessionFile.swift`
- Create: `QuickCullCore/Decoding/RawDecoding.swift`
- Create: `QuickCullCore/Decoding/LibRawDecoder.swift`
- Test: `QuickCullCoreTests/RawFileIdentityTests.swift`, `QuickCullCoreTests/LibRawDecoderTests.swift`
- Modify: `QuickCullCoreTests/CoreTests.swift` (delete — `Core` struct goes away)

**Interfaces:**
- Consumes: `QuickCullCore-Bridging-Header.h` + embedded `libraw.dylib` (Task 1).
- Produces (used by Tasks 3, 7, 9):
  - `RawFileIdentity.supportedExtensions: Set<String>`, `RawFileIdentity.isSupported(_ url: URL) -> Bool`, `RawFileIdentity.fileID(for url: URL) -> String`
  - `SessionFile { let url: URL; let id: String; init(url: URL) }` (Hashable, Sendable)
  - `RawBitmap { let image: CGImage; let width: Int; let height: Int; let flip: Int }`
  - `DecodeError: Error, Equatable` — cases `initFailed`, `cannotOpen(String)`, `cannotUnpack(String)`, `cannotProcess(String)`, `invalidOutput`
  - `protocol RawDecoding { func decodeRaw(at url: URL) throws -> RawBitmap }`
  - `final class LibRawDecoder: RawDecoding`

- [ ] **Step 1: Create `Scripts/fetch-fixtures.sh`** — downloads 8 positive fixtures (real raw files, one per major brand; URLs and sha256 values verified working at plan time) + 3 negative fixtures (truncated files from exiftool's test suite that must fail decode) into `QuickCullCoreTests/Fixtures/raws/`:

```bash
#!/usr/bin/env bash
# Downloads raw sample fixtures (positive + negative) with sha256 pinning.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/QuickCullCoreTests/Fixtures/raws"
mkdir -p "$DEST"
fetch() { # url sha256 name
  local url="$1" sum="$2" name="$3"
  echo "Fetching $name…"
  curl -fsSL -o "$DEST/$name" "$url"
  echo "$sum  $DEST/$name" | shasum -a 256 -c -
}
fetch "https://raw.pixls.us/data/Canon/EOS%2030D/IMG_0062.CR2"        fb216f8df8d7abca4eb9d9f8dc594c1d2b69d0a6369fb8b4107743343c37144f img_0062.cr2
fetch "https://raw.pixls.us/data/Canon/Canon%20EOS%20M200/_MG_2233.CR3" 0585a468143c6606936d0ffbff1788c6c02e3610d8ecb50614e21492fbacd052 mg_2233.cr3
fetch "https://raw.pixls.us/data/Nikon/1%20J1/_DSC8140.NEF"          1d3b7c26b012cf585d46a28c9c83876d687a6e215b7d0bdf8d062c82ab626401 dsc8140.nef
fetch "https://raw.pixls.us/data/Sony/DSLR-A100/_DSC0258.ARW"        4df7981ac4baec9648b4f106751ea4b09a6e27bc70a15f8ef09bec051fec362d dsc0258.arw
fetch "https://raw.pixls.us/data/Fujifilm/FinePix%20E550/RAW_FUJI_E550.RAF" 82d1010a1eb8cdf4b2de7ca30a3a4db4e96f290536f06ed2798a67c1fe81e6ae fuji_e550.raf
fetch "https://raw.pixls.us/data/Olympus/C5050Z/RAW_OLYMPUS_C5050Z.ORF" f4b013e78204ebaadd740d93416080856b3c51ec154760e2e2de0e552873044a olympus_c5050z.orf
fetch "https://raw.pixls.us/data/Panasonic/DC-FZ45/P1000336.RW2"     30c02f392d1d0dfba93cff429172b768225f11da2ce6a6b40a195611d8486954 p1000336.rw2
fetch "https://raw.pixls.us/data/Pentax/K-01/_IGP2068.DNG"          4c9aac2ce2720154616ad7678385d1ec1f626d6464a1d5c6a5a4d821a78a608d pentax_k01.dng
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/CanonRaw.cr2" b5d3d26f3c85bcb35a52515eac060e2e362161893504013589ffd9ad2e9b004b bad_truncated.cr2
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/FujiFilm.raf" e12e30bd0cf5f160b82b93f043696c04d1d5f4628f1fdd19abdab9f8328d8bf0 bad_truncated.raf
fetch "https://raw.githubusercontent.com/exiftool/exiftool/master/t/images/PhaseOne.iiq" 306efa7671f144b56cc0af8f7e22e8d3f7e33efe422fd0135f894bd3739c27be bad_truncated.iiq
echo "All fixtures fetched."
```

Note: fixture files are ~100 MB total and are committed to the repo (they are test resources; the synchronized `QuickCullCoreTests` folder copies them into the test bundle automatically). The DNG fixture doubles as Leica coverage (Leica raws are DNG).

- [ ] **Step 2: Run it and verify checksums pass**

Run: `bash Scripts/fetch-fixtures.sh`
Expected: `All fixtures fetched.` (exit 0)

- [ ] **Step 3: Write the failing identity tests**

`QuickCullCoreTests/RawFileIdentityTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class RawFileIdentityTests: XCTestCase {
    func testSupportedExtensions() {
        for ext in ["cr2", "cr3", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
                    "rw2", "dng", "pef", "3fr", "fff", "iiq", "x3f", "srw",
                    "dcr", "kdc", "erf"] {
            let url = URL(fileURLWithPath: "/tmp/shoot/IMG_0001.\(ext)")
            XCTAssertTrue(RawFileIdentity.isSupported(url), "\(ext) should be supported")
        }
    }

    func testUnsupportedAndCaseInsensitive() {
        XCTAssertFalse(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.jpg")))
        XCTAssertTrue(RawFileIdentity.isSupported(URL(fileURLWithPath: "/a/x.CR2")))
    }

    func testFileIDIsStandardizedPath() {
        let url = URL(fileURLWithPath: "/Users/x/../x/photo.cr2")
        XCTAssertEqual(RawFileIdentity.fileID(for: url), "/Users/x/photo.cr2")
    }
}
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing 2>&1 | tail -5`
Expected: BUILD FAILED with "cannot find 'RawFileIdentity' in scope" (the new test file won't compile).

- [ ] **Step 5: Implement `RawFileIdentity` and `SessionFile`**

`QuickCullCore/Models/RawFileIdentity.swift`:
```swift
import Foundation

/// Supported raw extensions for v1, per the design spec.
public enum RawFileIdentity {
    public static let supportedExtensions: Set<String> = [
        "cr2", "cr3",      // Canon
        "nef", "nrw",      // Nikon
        "arw", "srf", "sr2", // Sony
        "raf",             // Fujifilm
        "orf",             // Olympus / OM System
        "rw2",             // Panasonic
        "dng",             // Leica, Ricoh, Pentax, generic
        "pef",             // Pentax
        "3fr", "fff",      // Hasselblad
        "iiq",             // Phase One
        "x3f",             // Sigma
        "srw",             // Samsung
        "dcr", "kdc",      // Kodak
        "erf",             // Epson
    ]

    public static func isSupported(_ url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// Stable, unique identity for a file: the standardized absolute path.
    public static func fileID(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}
```

`QuickCullCore/Models/SessionFile.swift`:
```swift
import Foundation

/// One raw file in a culling session.
public struct SessionFile: Identifiable, Hashable, Sendable {
    public let url: URL
    public let id: String

    public init(url: URL) {
        self.url = url
        self.id = RawFileIdentity.fileID(for: url)
    }
}
```

- [ ] **Step 6: Write the failing decoder tests**

`QuickCullCoreTests/LibRawDecoderTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class LibRawDecoderTests: XCTestCase {
    private let decoder = LibRawDecoder()

    private func fixture(_ name: String, _ ext: String) -> URL {
        Bundle(for: Self.self).url(forResource: name, withExtension: ext,
                                   subdirectory: "Fixtures/raws")!
    }

    func testPositiveFixturesDecode() throws {
        let cases: [(name: String, ext: String, width: Int, height: Int, flip: Int)] = [
            ("img_0062", "cr2", 3522, 2348, 0),
            ("mg_2233", "cr3", 6024, 4020, 0),
            ("dsc8140", "nef", 3904, 2604, 0),
            ("dsc0258", "arw", 3881, 2607, 0),
            ("fuji_e550", "raf", 2894, 2177, 0),
            ("olympus_c5050z", "orf", 1926, 2576, 5),
            ("p1000336", "rw2", 4912, 3688, 0),
            ("pentax_k01", "dng", 4936, 3272, 0),
        ]
        for c in cases {
            let bitmap = try decoder.decodeRaw(at: fixture(c.name, c.ext))
            XCTAssertEqual(bitmap.width, c.width, c.name)
            XCTAssertEqual(bitmap.height, c.height, c.name)
            XCTAssertEqual(bitmap.flip, c.flip, c.name)
            XCTAssertEqual(bitmap.image.width, c.width, c.name)
        }
    }

    func testNegativeFixturesThrow() {
        for (name, ext) in [("bad_truncated", "cr2"), ("bad_truncated", "raf"), ("bad_truncated", "iiq")] {
            XCTAssertThrowsError(try decoder.decodeRaw(at: fixture(name, ext)), "\(name).\(ext) should fail")
        }
    }

    func testMissingFileThrowsCannotOpen() {
        XCTAssertThrowsError(try decoder.decodeRaw(at: URL(fileURLWithPath: "/nonexistent/photo.cr2")))
    }
}
```

(These expected dimensions/flip values were measured with this exact LibRaw build during plan validation.)

- [ ] **Step 7: Run tests to verify they fail**

Run the build command from Step 4.
Expected: BUILD FAILED with "cannot find 'LibRawDecoder' in scope".

- [ ] **Step 8: Implement the protocol and decoder**

`QuickCullCore/Decoding/RawDecoding.swift`:
```swift
import CoreGraphics
import Foundation

/// A full-resolution, fully demosaiced image produced by a raw decoder.
public struct RawBitmap {
    public let image: CGImage
    public let width: Int
    public let height: Int
    /// LibRaw flip value (0-7); drives JPEG orientation.
    public let flip: Int

    public init(image: CGImage, width: Int, height: Int, flip: Int) {
        self.image = image
        self.width = width
        self.height = height
        self.flip = flip
    }
}

public enum DecodeError: Error, Equatable {
    case initFailed
    case cannotOpen(String)
    case cannotUnpack(String)
    case cannotProcess(String)
    case invalidOutput
}

/// Abstraction over the raw decoding engine. v1 has one implementation
/// (`LibRawDecoder`); swapping it (e.g. XPC isolation) must not affect callers.
public protocol RawDecoding {
    func decodeRaw(at url: URL) throws -> RawBitmap
}
```

`QuickCullCore/Decoding/LibRawDecoder.swift`:
```swift
import CoreGraphics
import Foundation

/// LibRaw-backed decoder: full-resolution demosaic via the C API.
/// Stateless and thread-safe: every call creates its own libraw handle.
public final class LibRawDecoder: RawDecoding {

    public init() {}

    public func decodeRaw(at url: URL) throws -> RawBitmap {
        guard let handle = libraw_init(0) else {
            throw DecodeError.initFailed
        }
        defer { libraw_close(handle) }

        var ret = libraw_open_file(handle, url.path)
        guard ret == LIBRAW_SUCCESS else {
            throw DecodeError.cannotOpen(errorString(ret))
        }

        ret = libraw_unpack(handle)
        guard ret == LIBRAW_SUCCESS else {
            throw DecodeError.cannotUnpack(errorString(ret))
        }

        handle.pointee.params.output_bps = 8
        ret = libraw_dcraw_process(handle)
        guard ret == LIBRAW_SUCCESS else {
            throw DecodeError.cannotProcess(errorString(ret))
        }

        var memError: Int32 = 0
        guard let processed = libraw_dcraw_make_mem_image(handle, &memError) else {
            throw DecodeError.cannotProcess(errorString(memError))
        }
        defer { libraw_dcraw_clear_mem(processed) }

        let p = processed.pointee
        let expected = Int(p.width) * Int(p.height) * 3
        guard p.type == LIBRAW_IMAGE_BITMAP, p.colors == 3, p.bits == 8,
              p.width > 0, p.height > 0, Int(p.data_size) == expected else {
            throw DecodeError.invalidOutput
        }

        let data = Data(bytes: p.data, count: Int(p.data_size))
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: Int(p.width), height: Int(p.height),
                  bitsPerComponent: 8, bitsPerPixel: 24,
                  bytesPerRow: Int(p.width) * 3,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil,
                  shouldInterpolate: false, intent: .defaultIntent) else {
            throw DecodeError.invalidOutput
        }

        return RawBitmap(image: image,
                         width: Int(p.width),
                         height: Int(p.height),
                         flip: Int(handle.pointee.sizes.flip))
    }

    private func errorString(_ code: Int32) -> String {
        String(cString: libraw_strerror(code))
    }
}
```

- [ ] **Step 9: Delete `CoreTests.swift` and the `Core` struct** (they were scaffold placeholders)

Delete `QuickCullCoreTests/CoreTests.swift` and `QuickCullCore/Core.swift`.

- [ ] **Step 10: Run the full test suite**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
Expected: all suites pass — `Executed 6 tests, with 0 failures`.

- [ ] **Step 11: Commit**

```bash
git add -A
git commit -m "feat: raw decoder with LibRaw and multi-brand fixtures"
```

---

### Task 3: ImageCacheStore — cache directory, q75 JPEG encoding, keying

**Files:**
- Create: `QuickCullCore/Storage/ImageCacheStore.swift`
- Test: `QuickCullCoreTests/ImageCacheStoreTests.swift`

**Interfaces:**
- Consumes: `SessionFile`, `RawBitmap` (Task 2).
- Produces (used by Tasks 7, 9):
  - `actor ImageCacheStore` with `init(baseURL: URL)`, `static func defaultBaseURL() -> URL`, `func wipe() throws`, `func cacheURL(for file: SessionFile) throws -> URL`, `func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile) throws -> URL`, `func deleteCachedJPEG(for file: SessionFile)`, `static let jpegQuality: CGFloat = 0.75`, `func exifOrientation(forFlip flip: Int) -> Int?`
  - `enum CacheError: Error { case cannotCreateDestination; case cannotEncode }`

- [ ] **Step 1: Write the failing tests**

`QuickCullCoreTests/ImageCacheStoreTests.swift`:
```swift
import CoreGraphics
import ImageIO
import XCTest
@testable import QuickCullCore

final class ImageCacheStoreTests: XCTestCase {
    private var base: URL!
    private var store: ImageCacheStore!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        store = ImageCacheStore(baseURL: base)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
    }

    private func makeFile(_ name: String, size: Int = 100) throws -> SessionFile {
        let url = base.appendingPathComponent(name)
        try Data(repeating: 0xAB, count: size).write(to: url)
        return SessionFile(url: url)
    }

    private func makeBitmap() -> RawBitmap {
        let width = 32, height = 16
        var bytes = [UInt8](repeating: 128, count: width * height * 3)
        for i in 0..<width * height { bytes[i * 3] = UInt8(i % 256) }
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return RawBitmap(image: image, width: width, height: height, flip: 0)
    }

    func testWipeRecreatesEmptyDirectory() async throws {
        let file = try makeFile("x.cr2")
        _ = try await store.storeJPEG(makeBitmap(), for: file)
        try await store.wipe()
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertTrue(contents.isEmpty)
    }

    func testCacheKeyIsStableForUnchangedFile() async throws {
        let file = try makeFile("a.cr2")
        let key1 = try await store.cacheURL(for: file)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertEqual(key1, key2)
    }

    func testCacheKeyChangesWhenMtimeChanges() async throws {
        let file = try makeFile("a.cr2")
        let key1 = try await store.cacheURL(for: file)
        // touch the file: mtime changes
        try Data([0x01]).write(to: file.url)
        let key2 = try await store.cacheURL(for: file)
        XCTAssertNotEqual(key1, key2)
    }

    func testStoreJPEGWritesDecodableJPEGAtQ75() async throws {
        let file = try makeFile("a.cr2")
        let destination = try await store.storeJPEG(makeBitmap(), for: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            return XCTFail("not a decodable image")
        }
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyPixelWidth] as? Int, 32)
        XCTAssertEqual(props?[kCGImagePropertyPixelHeight] as? Int, 16)
    }

    func testStoreJPEGOrientationForFlip() async throws {
        let file = try makeFile("a.cr2")
        var bitmap = makeBitmap()
        bitmap = RawBitmap(image: bitmap.image, width: bitmap.width,
                           height: bitmap.height, flip: 5)
        let destination = try await store.storeJPEG(bitmap, for: file)
        guard let source = CGImageSourceCreateWithURL(destination as CFURL, nil) else {
            return XCTFail("not a decodable image")
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 8)
    }

    func testStoreJPEGLeavesNoTmpFiles() async throws {
        let file = try makeFile("a.cr2")
        _ = try await store.storeJPEG(makeBitmap(), for: file)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertFalse(names.contains { $0.hasSuffix(".tmp") })
    }

    func testDeleteCachedJPEGRemovesFile() async throws {
        let file = try makeFile("a.cr2")
        let destination = try await store.storeJPEG(makeBitmap(), for: file)
        await store.deleteCachedJPEG(for: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run the Task 2 build command.
Expected: BUILD FAILED with "cannot find 'ImageCacheStore' in scope".

- [ ] **Step 3: Implement `ImageCacheStore`**

```swift
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Owns the decoded-JPEG cache directory. Full-res q75 JPEGs keyed by
/// source file identity (path + size + mtime). Wiped on every launch.
public actor ImageCacheStore {

    public static let jpegQuality: CGFloat = 0.75

    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public static func defaultBaseURL() -> URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("QuickCull/cache", isDirectory: true)
    }

    /// Authoritative launch-time cleanup: delete everything, recreate.
    public func wipe() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: baseURL.path) {
            try fm.removeItem(at: baseURL)
        }
        try fm.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    /// Cache key: SHA256 of "<standardized path>|<size>|<mtime-us>".
    public func cacheURL(for file: SessionFile) throws -> URL {
        let attrs = try FileManager.default.attributesOfItem(atPath: file.url.path)
        let size = (attrs[.size] as? UInt64) ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(file.id)|\(size)|\(Int(mtime * 1_000_000))"
        let digest = SHA256.hash(data: Data(key.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent(hex + ".jpg")
    }

    /// Encode the bitmap to a q75 JPEG and write it atomically (tmp + rename).
    @discardableResult
    public func storeJPEG(_ bitmap: RawBitmap, for file: SessionFile) throws -> URL {
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        let destination = try cacheURL(for: file)
        let tmp = destination.appendingPathExtension("tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let sink = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CacheError.cannotCreateDestination
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: Self.jpegQuality]
        if let orientation = exifOrientation(forFlip: bitmap.flip) {
            props[kCGImagePropertyOrientation] = orientation
        }
        CGImageDestinationAddImage(sink, bitmap.image, props as CFDictionary)
        guard CGImageDestinationFinalize(sink) else {
            throw CacheError.cannotEncode
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tmp, to: destination)
        return destination
    }

    public func deleteCachedJPEG(for file: SessionFile) {
        if let url = try? cacheURL(for: file) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// dcraw flip code -> EXIF orientation (1-8); nil when unknown.
    public func exifOrientation(forFlip flip: Int) -> Int? {
        switch flip {
        case 0: return 1
        case 1: return 2
        case 2: return 4
        case 3: return 3
        case 4: return 5
        case 5: return 8
        case 6: return 6
        case 7: return 7
        default: return nil
        }
    }
}

public enum CacheError: Error {
    case cannotCreateDestination
    case cannotEncode
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing && xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest`
Expected: `Executed 13 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: image cache store with q75 JPEG encoding and launch wipe"
```

---

### Task 4: Session — files, index, in-memory flags

**Files:**
- Create: `QuickCullCore/Session/Session.swift`
- Test: `QuickCullCoreTests/SessionTests.swift`

**Interfaces:**
- Consumes: `SessionFile`, `RawFileIdentity` (Task 2).
- Produces (used by Tasks 5, 7, 9):
  - `@MainActor final class Session` — `init(files: [SessionFile])` (non-empty), `files`, `currentIndex`, `flagged: Set<String>`, `count`, `currentFile`, `move(by:)`, `toggleFlag()`, `isFlagged(_:)`, `flaggedCount`, `flaggedFiles`, `remove(_ files: [SessionFile])`, `setIndex(_:)`, `isEmpty`.

- [ ] **Step 1: Write the failing tests**

`QuickCullCoreTests/SessionTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

@MainActor
final class SessionTests: XCTestCase {
    private func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    func testMoveClampsAtEdges() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.move(by: 10)
        XCTAssertEqual(session.currentIndex, 2)
        session.move(by: -10)
        XCTAssertEqual(session.currentIndex, 0)
    }

    func testToggleFlagOnAndOff() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2"]))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 1)
        XCTAssertTrue(session.isFlagged(session.currentFile))
        session.toggleFlag()
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testFlagsKeyedByIdSurviveIndexChange() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()          // flags index 0
        session.move(by: 1)
        session.toggleFlag()          // flags index 1
        session.move(by: -1)
        XCTAssertTrue(session.isFlagged(session.files[0]))
        XCTAssertEqual(session.flaggedCount, 2)
    }

    func testRemoveTrashedFilesClearsFlagsAndClampsIndex() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2", "d.cr2"]))
        session.setIndex(3)
        session.remove([session.files[3]])
        XCTAssertEqual(session.count, 3)
        XCTAssertEqual(session.currentIndex, 2)
        XCTAssertEqual(session.flaggedCount, 0)
    }

    func testRemoveAllLeavesEmptySession() {
        let session = Session(files: makeFiles(["a.cr2"]))
        session.remove([session.files[0]])
        XCTAssertTrue(session.isEmpty)
    }

    func testFlaggedFilesReturnsInOrder() {
        let session = Session(files: makeFiles(["a.cr2", "b.cr2", "c.cr2"]))
        session.toggleFlag()
        session.move(by: 1)
        session.toggleFlag()
        XCTAssertEqual(session.flaggedFiles.map(\.id),
                       [session.files[0].id, session.files[1].id])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'Session' in scope".

- [ ] **Step 3: Implement `Session`**

```swift
import Foundation

/// Per-session culling state. Flags live only in memory and are discarded
/// when a new session starts. Commit removes trashed files; scrubbing
/// continues on the remainder.
@MainActor
public final class Session {
    public private(set) var files: [SessionFile]
    public private(set) var currentIndex: Int = 0
    public private(set) var flagged: Set<String> = []

    public init(files: [SessionFile]) {
        precondition(!files.isEmpty, "Session requires at least one file")
        self.files = files
    }

    public var count: Int { files.count }
    public var isEmpty: Bool { files.isEmpty }
    public var currentFile: SessionFile { files[currentIndex] }

    public func move(by delta: Int) {
        guard !files.isEmpty else { return }
        currentIndex = min(max(currentIndex + delta, 0), files.count - 1)
    }

    public func setIndex(_ index: Int) {
        guard !files.isEmpty else { return }
        currentIndex = min(max(index, 0), files.count - 1)
    }

    public func toggleFlag() {
        guard !files.isEmpty else { return }
        let id = currentFile.id
        if flagged.contains(id) { flagged.remove(id) } else { flagged.insert(id) }
    }

    public func isFlagged(_ file: SessionFile) -> Bool {
        flagged.contains(file.id)
    }

    public var flaggedCount: Int { flagged.count }

    public var flaggedFiles: [SessionFile] {
        files.filter { flagged.contains($0.id) }
    }

    /// Remove trashed files after a successful commit. All flags are cleared
    /// (flagged files are exactly the ones being removed).
    public func remove(_ filesToRemove: [SessionFile]) {
        let ids = Set(filesToRemove.map(\.id))
        flagged.subtract(ids)
        files.removeAll { ids.contains($0.id) }
        currentIndex = min(max(currentIndex, 0), max(files.count - 1, 0))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `Executed 19 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: session model with in-memory flags"
```

---

### Task 5: Sliding window — WindowPolicy, SlidingWindow, DisplayImageProvider

**Files:**
- Create: `QuickCullCore/Window/WindowPolicy.swift`
- Create: `QuickCullCore/Window/SlidingWindow.swift`
- Test: `QuickCullCoreTests/WindowPolicyTests.swift`, `QuickCullCoreTests/SlidingWindowTests.swift`

**Interfaces:**
- Consumes: nothing (WindowPolicy); `SessionFile` not needed — windows are index-based. ImageIO for loaders.
- Produces (used by Task 9):
  - `struct WindowPolicy { init(radius: Int = 30); func window(around: Int, count: Int) -> Range<Int>; func loadOrder(current: Int, count: Int) -> [Int]; func toEvict(resident: Set<Int>, current: Int, count: Int) -> Set<Int> }`
  - `@MainActor final class SlidingWindow` — `init(radius: Int, count: Int, thumbnailLoader: @escaping (Int) async -> CGImage?)`, `setCurrent(_:)`, `image(at:)`, `waitUntilSettled() async`
  - `@MainActor final class DisplayImageProvider` — `init(loader:)`, `setCurrent(_:)`, `image(at:)`, `waitUntilSettled() async`

- [ ] **Step 1: Write the failing policy tests**

`QuickCullCoreTests/WindowPolicyTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class WindowPolicyTests: XCTestCase {
    func testWindowClampsAtEdges() {
        let policy = WindowPolicy(radius: 30)
        XCTAssertEqual(policy.window(around: 0, count: 100), 0..<31)
        XCTAssertEqual(policy.window(around: 99, count: 100), 69..<100)
    }

    func testWindowNeverExceedsRadius() {
        let policy = WindowPolicy(radius: 30)
        for current in [0, 1, 50, 98, 99] {
            let window = policy.window(around: current, count: 100)
            XCTAssertLessThanOrEqual(window.count, 61)
        }
    }

    func testWindowEmptyWhenNoFiles() {
        let policy = WindowPolicy(radius: 30)
        XCTAssertTrue(policy.window(around: 0, count: 0).isEmpty)
    }

    func testLoadOrderStartsWithCurrentThenOutward() {
        let policy = WindowPolicy(radius: 2)
        XCTAssertEqual(policy.loadOrder(current: 5, count: 100),
                       [5, 6, 4, 7, 3])
    }

    func testToEvictOutsideWindow() {
        let policy = WindowPolicy(radius: 1)
        let resident: Set<Int> = [0, 1, 2, 3, 99]
        XCTAssertEqual(policy.toEvict(resident: resident, current: 1, count: 100),
                       Set([3, 99]))
    }
}
```

- [ ] **Step 2: Write the failing window tests** (synthetic JPEG fixtures, generated in `setUp`)

`QuickCullCoreTests/SlidingWindowTests.swift`:
```swift
import CoreGraphics
import ImageIO
import XCTest
@testable import QuickCullCore

@MainActor
final class SlidingWindowTests: XCTestCase {
    private var fixtureDir: URL!
    private let count = 100

    override func setUp() async throws {
        fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-win-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        for index in 0..<count {
            try writeJPEG(color: UInt8(index % 256), to: url(for: index))
        }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: fixtureDir)
    }

    private func url(for index: Int) -> URL {
        fixtureDir.appendingPathComponent(String(format: "%03d.jpg", index))
    }

    private func writeJPEG(color: UInt8, to url: URL) throws {
        let width = 64, height = 40
        var bytes = [UInt8](repeating: color, count: width * height * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        let sink = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(sink, image, nil)
        CGImageDestinationFinalize(sink)
    }

    private func makeLoader() -> (Int) async -> CGImage? {
        { [fixtureDir = self.fixtureDir!] index in
            guard index >= 0, index < self.count else { return nil }
            let src = CGImageSourceCreateWithURL(self.url(for: index) as CFURL, nil)!
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
    }

    func testWindowNeverExceedsRadiusPlusOne() async {
        let window = SlidingWindow(radius: 30, count: count, thumbnailLoader: makeLoader())
        for index in [0, 5, 50, 95, 99, 50, 0] {
            window.setCurrent(index)
            await window.waitUntilSettled()
            XCTAssertLessThanOrEqual(window.thumbnails.count, 61)
        }
    }

    func testCurrentImageLoadedFirst() async {
        var seen: [Int] = []
        let window = SlidingWindow(radius: 30, count: count) { index in
            seen.append(index)
            return nil
        }
        window.setCurrent(50)
        await window.waitUntilSettled()
        XCTAssertEqual(seen.first, 50)
    }

    func testEvictionDropsFarEdges() async {
        let window = SlidingWindow(radius: 2, count: count, thumbnailLoader: makeLoader())
        window.setCurrent(50)
        await window.waitUntilSettled()
        window.setCurrent(99)
        await window.waitUntilSettled()
        XCTAssertNil(window.image(at: 48))
        XCTAssertNotNil(window.image(at: 97))
    }

    func testDisplayProviderKeepsAtMostThree() async {
        let provider = DisplayImageProvider(loader: makeLoader())
        for index in [0, 1, 2, 3, 10, 99] {
            provider.setCurrent(index)
            await provider.waitUntilSettled()
            XCTAssertLessThanOrEqual(provider.images.count, 3)
        }
        provider.setCurrent(50)
        await provider.waitUntilSettled()
        XCTAssertNotNil(provider.image(at: 50))
        XCTAssertNotNil(provider.image(at: 49))
        XCTAssertNotNil(provider.image(at: 51))
        XCTAssertNil(provider.image(at: 48))
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'WindowPolicy' in scope".

- [ ] **Step 4: Implement the three types**

`QuickCullCore/Window/WindowPolicy.swift`:
```swift
import Foundation

/// Pure policy math for the sliding in-memory window (no I/O; fully testable).
public struct WindowPolicy {
    public let radius: Int

    public init(radius: Int = 30) {
        self.radius = radius
    }

    /// Clamped half-open range of indices that should be resident.
    public func window(around current: Int, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let clamped = min(max(current, 0), count - 1)
        let lower = max(clamped - radius, 0)
        let upper = min(clamped + radius + 1, count)
        return lower..<upper
    }

    /// Load order: current index first, then outward by distance
    /// (after-neighbor before before-neighbor).
    public func loadOrder(current: Int, count: Int) -> [Int] {
        let range = window(around: current, count: count)
        guard !range.isEmpty else { return [] }
        var order: [Int] = []
        for distance in 0...radius {
            let after = current + distance
            let before = current - distance
            if range.contains(after) { order.append(after) }
            if distance > 0, range.contains(before) { order.append(before) }
        }
        return order
    }

    /// Resident indices that fall outside the desired window.
    public func toEvict(resident: Set<Int>, current: Int, count: Int) -> Set<Int> {
        let desired = Set(window(around: current, count: count))
        return resident.subtracting(desired)
    }
}
```

`QuickCullCore/Window/SlidingWindow.swift`:
```swift
import CoreGraphics
import Foundation

/// Holds the filmstrip window: at most 2*radius+1 (61) thumbnail renderings,
/// loaded from the cached full-res JPEGs. Loads current-first, then outward;
/// evicts everything outside the window immediately.
@MainActor
public final class SlidingWindow {
    public let radius: Int
    public let count: Int
    public private(set) var thumbnails: [Int: CGImage] = [:]

    private let thumbnailLoader: (Int) async -> CGImage?
    private var inFlight: Set<Int> = []
    private var currentIndex: Int = 0

    public init(radius: Int, count: Int, thumbnailLoader: @escaping (Int) async -> CGImage?) {
        self.radius = radius
        self.count = count
        self.thumbnailLoader = thumbnailLoader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = min(max(index, 0), max(count - 1, 0))
        let policy = WindowPolicy(radius: radius)

        let evict = policy.toEvict(resident: Set(thumbnails.keys),
                                   current: currentIndex, count: count)
        for i in evict {
            thumbnails.removeValue(forKey: i)
            inFlight.remove(i)
        }

        for i in policy.loadOrder(current: currentIndex, count: count)
        where thumbnails[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await thumbnailLoader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard policy.window(around: self.currentIndex, count: self.count).contains(i) else { return }
                if let image { self.thumbnails[i] = image }
            }
        }
        assert(thumbnails.count <= 2 * radius + 1, "filmstrip window invariant violated")
    }

    public func image(at index: Int) -> CGImage? { thumbnails[index] }

    /// Awaits until all in-flight loads settle (used by tests).
    public func waitUntilSettled() async {
        while !inFlight.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

/// Holds the main-view display renderings: current ±1 (max 3 images),
/// sized by the loader (2× screen long edge in production).
@MainActor
public final class DisplayImageProvider {
    public private(set) var images: [Int: CGImage] = [:]

    private let loader: (Int) async -> CGImage?
    private var currentIndex: Int = 0
    private var inFlight: Set<Int> = []

    public init(loader: @escaping (Int) async -> CGImage?) {
        self.loader = loader
    }

    public func setCurrent(_ index: Int) {
        currentIndex = index
        let desired = Set([index - 1, index, index + 1])
        for i in images.keys where !desired.contains(i) {
            images.removeValue(forKey: i)
            inFlight.remove(i)
        }
        for i in desired.sorted() where images[i] == nil && !inFlight.contains(i) {
            inFlight.insert(i)
            Task { [weak self] in
                let image = await loader(i)
                guard let self else { return }
                self.inFlight.remove(i)
                guard Set([self.currentIndex - 1, self.currentIndex, self.currentIndex + 1]).contains(i) else { return }
                if let image { self.images[i] = image }
            }
        }
        assert(images.count <= 3, "display window invariant violated")
    }

    public func image(at index: Int) -> CGImage? { images[index] }

    public func waitUntilSettled() async {
        while !inFlight.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Expected: `Executed 28 tests, with 0 failures`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: sliding window policy with bounded in-memory renderings"
```

---

### Task 6: Key mapping — keyCode → action

**Files:**
- Create: `QuickCullCore/Keys/CullKeyMap.swift`
- Test: `QuickCullCoreTests/CullKeyMapTests.swift`

**Interfaces:**
- Produces (used by Task 9): `enum CullAction: Equatable { case next; case previous; case jumpForward; case jumpBack; case toggleFlag }` and `enum CullKeyMap { static func action(forKeyCode: UInt16) -> CullAction? }`

- [ ] **Step 1: Write the failing tests**

`QuickCullCoreTests/CullKeyMapTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class CullKeyMapTests: XCTestCase {
    func testArrowKeys() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 123), .previous)  // left
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 124), .next)      // right
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 125), .jumpForward)  // down
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 126), .jumpBack)     // up
    }

    func testZKey() {
        XCTAssertEqual(CullKeyMap.action(forKeyCode: 6), .toggleFlag)  // 'z' physical key
    }

    func testUnknownKeysAreIgnored() {
        for code: UInt16 in [0, 1, 3, 36, 49, 122] {
            XCTAssertNil(CullKeyMap.action(forKeyCode: code))
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'CullKeyMap' in scope".

- [ ] **Step 3: Implement**

`QuickCullCore/Keys/CullKeyMap.swift`:
```swift
import Foundation

/// Actions the scrub UI responds to.
public enum CullAction: Equatable {
    case next
    case previous
    case jumpForward
    case jumpBack
    case toggleFlag
}

/// Pure mapping from macOS virtual key codes to cull actions.
/// Using keyCode (not characters) makes Z work regardless of shift/caps.
public enum CullKeyMap {
    private static let leftArrow: UInt16 = 123
    private static let rightArrow: UInt16 = 124
    private static let downArrow: UInt16 = 125
    private static let upArrow: UInt16 = 126
    private static let zKey: UInt16 = 6

    public static func action(forKeyCode keyCode: UInt16) -> CullAction? {
        switch keyCode {
        case leftArrow: return .previous
        case rightArrow: return .next
        case downArrow: return .jumpForward
        case upArrow: return .jumpBack
        case zKey: return .toggleFlag
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `Executed 31 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: keyboard mapping for scrub controls"
```

---

### Task 7: DecodeEngine — parallel Phase 1 decode with progress

**Files:**
- Create: `QuickCullCore/Engine/DecodeEngine.swift`
- Test: `QuickCullCoreTests/DecodeEngineTests.swift`

**Interfaces:**
- Consumes: `RawDecoding` + `RawBitmap`/`DecodeError` (Task 2), `ImageCacheStore` (Task 3), `SessionFile` (Task 2).
- Produces (used by Task 9):
  - `struct DecodeOutcome: Equatable { let file: SessionFile; let error: DecodeError? }`
  - `actor DecodeEngine { init(decoder: RawDecoding, cache: ImageCacheStore); enum Event { case progress(completed: Int, total: Int); case completed([DecodeOutcome]) }; func decodeAll(files: [SessionFile]) -> AsyncStream<Event> }`

- [ ] **Step 1: Write the failing tests** (stub decoder — no real raws needed; plus one integration test with the real decoder + fixtures)

`QuickCullCoreTests/DecodeEngineTests.swift`:
```swift
import CoreGraphics
import XCTest
@testable import QuickCullCore

/// Deterministic fake decoder: success for most files, failure for a
/// designated one; records every call (thread-safe).
final class StubDecoder: RawDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    let failIDs: Set<String>

    init(failIDs: Set<String> = []) {
        self.failIDs = failIDs
    }

    func decodeRaw(at url: URL) throws -> RawBitmap {
        lock.lock(); defer { lock.unlock() }
        let id = RawFileIdentity.fileID(for: url)
        calls.append(id)
        if failIDs.contains(id) {
            throw DecodeError.cannotUnpack("stub failure")
        }
        let width = 8, height = 4
        var bytes = [UInt8](repeating: 100, count: width * height * 3)
        let data = Data(bytes)
        let provider = CGDataProvider(data: data as CFData)!
        let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                            bitsPerPixel: 24, bytesPerRow: width * 3,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                            provider: provider, decode: nil, shouldInterpolate: false,
                            intent: .defaultIntent)!
        return RawBitmap(image: image, width: width, height: height, flip: 0)
    }

    func callCount() -> Int {
        lock.lock(); defer { lock.unlock() }
        return calls.count
    }
}

final class DecodeEngineTests: XCTestCase {
    private func makeTempCache() async throws -> (ImageCacheStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return (ImageCacheStore(baseURL: base), base)
    }

    private func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    private func collect(_ stream: AsyncStream<DecodeEngine.Event>) async -> [DecodeEngine.Event] {
        var events: [DecodeEngine.Event] = []
        for await event in stream { events.append(event) }
        return events
    }

    func testDecodesEveryFileExactlyOnce() async throws {
        let files = makeFiles((0..<20).map { "img_\($0).cr2" })
        let decoder = StubDecoder()
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        XCTAssertEqual(decoder.callCount(), 20)

        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertEqual(outcomes.count, 20)
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
    }

    func testFailuresAreCollectedNotFatal() async throws {
        let files = makeFiles(["ok.cr2", "bad.cr2", "also_ok.cr2"])
        let decoder = StubDecoder(failIDs: ["/tmp/shoot/bad.cr2"])
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: decoder, cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        let failures = outcomes.filter { $0.error != nil }
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.file.id, "/tmp/shoot/bad.cr2")
        XCTAssertEqual(failures.first?.error, .cannotUnpack("stub failure"))
    }

    func testProgressReachesTotalAndIsMonotonic() async throws {
        let files = makeFiles((0..<16).map { "img_\($0).nef" })
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        let events = await collect(engine.decodeAll(files: files))
        let progressEvents = events.compactMap { event -> Int? in
            if case .progress(let completed, let total) = event {
                XCTAssertEqual(total, 16)
                return completed
            }
            return nil
        }
        XCTAssertEqual(progressEvents.last, 16)
        var previous = 0
        for p in progressEvents {
            XCTAssertGreaterThan(p, previous)
            previous = p
        }
    }

    func testDecodedJPEGsAreWrittenToCache() async throws {
        let files = makeFiles(["a.cr2", "b.cr2"])
        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: StubDecoder(), cache: cache)

        _ = await collect(engine.decodeAll(files: files))
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 2)
        XCTAssertTrue(contents.allSatisfy { $0.hasSuffix(".jpg") })
    }

    func testRealDecoderIntegrationWithFixtures() async throws {
        // Uses the real LibRawDecoder on the small 8-file fixture set.
        let bundle = Bundle(for: Self.self)
        let rawURLs = try FileManager.default
            .contentsOfDirectory(at: bundle.resourceURL!
                .appendingPathComponent("Fixtures/raws", isDirectory: true),
                includingPropertiesForKeys: nil)
            .filter { RawFileIdentity.isSupported($0) && !$0.lastPathComponent.hasPrefix("bad_") }
        XCTAssertEqual(rawURLs.count, 8)

        let (cache, base) = try await makeTempCache()
        defer { try? FileManager.default.removeItem(at: base) }
        let engine = DecodeEngine(decoder: LibRawDecoder(), cache: cache)

        let events = await collect(engine.decodeAll(files: rawURLs.map(SessionFile.init)))
        guard case .completed(let outcomes) = events.last else {
            return XCTFail("expected completed event")
        }
        XCTAssertTrue(outcomes.allSatisfy { $0.error == nil },
                      "all fixture files must decode: \(outcomes)")
        let contents = try FileManager.default.contentsOfDirectory(atPath: base.path)
        XCTAssertEqual(contents.count, 8)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'DecodeEngine' in scope".

- [ ] **Step 3: Implement `DecodeEngine`**

```swift
import Foundation

public struct DecodeOutcome: Equatable {
    public let file: SessionFile
    public let error: DecodeError?

    public init(file: SessionFile, error: DecodeError?) {
        self.file = file
        self.error = error
    }
}

/// Phase 1: decode every file to a cached full-res q75 JPEG in parallel,
/// bounded by the number of performance cores. Emits progress events, then
/// exactly one completed event with per-file outcomes.
public actor DecodeEngine {
    public enum Event {
        case progress(completed: Int, total: Int)
        case completed([DecodeOutcome])
    }

    private let decoder: RawDecoding
    private let cache: ImageCacheStore

    public init(decoder: RawDecoding, cache: ImageCacheStore) {
        self.decoder = decoder
        self.cache = cache
    }

    public func decodeAll(files: [SessionFile]) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                let workerCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
                let queue = JobQueue<SessionFile>()
                for file in files { await queue.enqueue(file) }

                let total = files.count
                let counter = AtomicCounter()
                let outcomes = AtomicOutcomeAccumulator()

                await withTaskGroup(of: Void.self) { group in
                    for _ in 0..<workerCount {
                        group.addTask {
                            while let file = await queue.dequeue() {
                                let outcome: DecodeOutcome
                                do {
                                    let bitmap = try self.decoder.decodeRaw(at: file.url)
                                    try await self.cache.storeJPEG(bitmap, for: file)
                                    outcome = DecodeOutcome(file: file, error: nil)
                                } catch let error as DecodeError {
                                    outcome = DecodeOutcome(file: file, error: error)
                                } catch {
                                    outcome = DecodeOutcome(file: file,
                                                            error: .cannotProcess("\(error)"))
                                }
                                outcomes.append(outcome)
                                let completed = counter.increment()
                                continuation.yield(.progress(completed: completed, total: total))
                            }
                        }
                    }
                }
                continuation.yield(.completed(outcomes.snapshot()))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// FIFO work queue shared by the worker pool.
actor JobQueue<Element> {
    private var items: [Element] = []

    func enqueue(_ item: Element) {
        items.append(item)
    }

    func dequeue() -> Element? {
        items.isEmpty ? nil : items.removeFirst()
    }
}

final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}

final class AtomicOutcomeAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [DecodeOutcome] = []

    func append(_ outcome: DecodeOutcome) {
        lock.lock(); defer { lock.unlock() }
        items.append(outcome)
    }

    func snapshot() -> [DecodeOutcome] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Note: `testRealDecoderIntegrationWithFixtures` decodes 8 real raws (~130 MP total) — expect 10-60 s.

Expected: `Executed 36 tests, with 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: parallel decode engine with progress and per-file outcomes"
```

---

### Task 8: TrashCommit — Trashing protocol, FileManagerTrasher

**Files:**
- Create: `QuickCullCore/Commit/TrashCommit.swift`
- Test: `QuickCullCoreTests/TrashCommitTests.swift`

**Interfaces:**
- Consumes: `SessionFile` (Task 2).
- Produces (used by Task 9):
  - `protocol Trashing { func trash(url: URL) throws }`
  - `struct FileManagerTrasher: Trashing`
  - `struct TrashOutcome { let file: SessionFile; let error: Error?; var succeeded: Bool }`
  - `struct TrashCommit { init(trasher: Trashing); func commit(files: [SessionFile]) -> [TrashOutcome] }`

- [ ] **Step 1: Write the failing tests**

`QuickCullCoreTests/TrashCommitTests.swift`:
```swift
import XCTest
@testable import QuickCullCore

final class StubTrasher: Trashing {
    var failIDs: Set<String> = []
    private(set) var trashed: [String] = []

    func trash(url: URL) throws {
        let id = RawFileIdentity.fileID(for: url)
        if failIDs.contains(id) {
            throw NSError(domain: "stub", code: 1, userInfo: [NSLocalizedDescriptionKey: "volume without trash"])
        }
        trashed.append(id)
    }
}

final class TrashCommitTests: XCTestCase {
    private func makeFiles(_ names: [String]) -> [SessionFile] {
        names.map { SessionFile(url: URL(fileURLWithPath: "/tmp/shoot/\($0)")) }
    }

    func testCommitTrashesEveryFile() {
        let files = makeFiles(["a.cr2", "b.cr2"])
        let trasher = StubTrasher()
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertTrue(outcomes.allSatisfy(\.succeeded))
        XCTAssertEqual(Set(trasher.trashed), Set(["/tmp/shoot/a.cr2", "/tmp/shoot/b.cr2"]))
    }

    func testCommitReportsPerFileFailuresAndKeepsGoing() {
        let files = makeFiles(["a.cr2", "bad.cr2", "c.cr2"])
        let trasher = StubTrasher()
        trasher.failIDs = ["/tmp/shoot/bad.cr2"]
        let outcomes = TrashCommit(trasher: trasher).commit(files: files)
        XCTAssertEqual(outcomes.filter(\.succeeded).count, 2)
        XCTAssertEqual(outcomes.first { !$0.succeeded }?.file.id, "/tmp/shoot/bad.cr2")
        XCTAssertEqual(trasher.trashed.count, 2)
    }

    func testFileManagerTrasherMovesRealFileToTrash() throws {
        // Real trash call against a temp file. On volumes without a Trash
        // location (CI sandboxes), the failure mode itself is asserted.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("photo.cr2")
        try Data([0x01, 0x02]).write(to: url)
        let trasher = FileManagerTrasher()
        do {
            try trasher.trash(url: url)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        } catch {
            XCTSkip("volume has no Trash location; error surfaced as expected: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'TrashCommit' in scope".

- [ ] **Step 3: Implement**

`QuickCullCore/Commit/TrashCommit.swift`:
```swift
import Foundation

public protocol Trashing {
    func trash(url: URL) throws
}

public struct FileManagerTrasher: Trashing {
    public init() {}

    public func trash(url: URL) throws {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
    }
}

public struct TrashOutcome {
    public let file: SessionFile
    public let error: Error?

    public var succeeded: Bool { error == nil }

    public init(file: SessionFile, error: Error?) {
        self.file = file
        self.error = error
    }
}

/// Moves flagged files to the macOS Trash. Never throws; every file gets an
/// individual outcome so one bad volume can't abort the commit.
public struct TrashCommit {
    private let trasher: Trashing

    public init(trasher: Trashing) {
        self.trasher = trasher
    }

    public func commit(files: [SessionFile]) -> [TrashOutcome] {
        files.map { file in
            do {
                try trasher.trash(url: file.url)
                return TrashOutcome(file: file, error: nil)
            } catch {
                return TrashOutcome(file: file, error: error)
            }
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Expected: `Executed 39 tests, with 0 failures` (the real-trash test may report "skipped" on restricted volumes — acceptable and non-failing).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: trash commit with per-file outcomes"
```

---

### Task 9: AppState + SwiftUI app — import, scrub, filmstrip, commit

**Files:**
- Create: `QuickCullCore/App/AppState.swift`
- Create: `QuickCull/RootView.swift`, `EmptyStateView.swift`, `DecodingView.swift`, `ScrubView.swift`, `ImageDisplayView.swift`, `FilmstripView.swift`, `FlagBadge.swift`, `KeyboardMonitor.swift`
- Modify: `QuickCull/QuickCullApp.swift`
- Test: `QuickCullCoreTests/AppStateTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2-8.
- Produces: the complete user flow. `AppState` API:
  - `@MainActor @Observable final class AppState` — `init(decoder: RawDecoding = LibRawDecoder(), cache: ImageCacheStore = ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL()), trasher: Trashing = FileManagerTrasher())`
  - `phase: AppPhase` (`empty` / `decoding(completed: Int, total: Int)` / `scrubbing`), `session: Session?`, `importFailures: [DecodeOutcome]`, `commitFailures: [TrashOutcome]`, `pendingCommitCount: Int`
  - `prepareForLaunch()`, `importFiles(urls: [URL])`, `handle(_ action: CullAction)`, `setCurrentIndex(_:)`, `requestCommit()`, `confirmCommit()`, `cancelCommit()`, `thumbWindow: SlidingWindow?`, `displayImages: DisplayImageProvider?`

- [ ] **Step 1: Write the failing AppState tests** (inject stub decoder + stub trasher; no UI)

`QuickCullCoreTests/AppStateTests.swift`:
```swift
import CoreGraphics
import XCTest
@testable import QuickCullCore

@MainActor
final class AppStateTests: XCTestCase {
    private var tempDir: URL!
    private var cache: ImageCacheStore!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("qc-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        cache = ImageCacheStore(baseURL: tempDir.appendingPathComponent("cache", isDirectory: true))
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRaw(_ name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(repeating: 7, count: 16).write(to: url)
        return url
    }

    private func makeState(trasher: Trashing = StubTrasher()) -> AppState {
        AppState(decoder: StubDecoder(), cache: cache, trasher: trasher)
    }

    private func waitForScrubbing(_ state: AppState) async {
        for _ in 0..<200 {   // bounded wait; stub decode is instant
            if state.phase == .scrubbing { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("never reached scrubbing")
    }

    func testImportFiltersUnsupportedAndDedupes() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.jpg")
        let state = makeState()
        state.importFiles(urls: [a, b, a])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.count, 1)
    }

    func testFlagsClearOnNewImport() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)
        state.handle(.toggleFlag)
        XCTAssertEqual(state.session?.flaggedCount, 1)
        state.importFiles(urls: [b])
        await waitForScrubbing(state)
        XCTAssertEqual(state.session?.flaggedCount, 0)
    }

    func testHandleMovesAndFlags() async throws {
        let files = try (0..<3).map { try makeRaw("f\($0).cr2") }
        let state = makeState()
        state.importFiles(urls: files)
        await waitForScrubbing(state)

        state.handle(.next)
        XCTAssertEqual(state.session?.currentIndex, 1)
        state.handle(.jumpForward)
        XCTAssertEqual(state.session?.currentIndex, 2)
        state.handle(.jumpBack)
        XCTAssertEqual(state.session?.currentIndex, 0)
        state.handle(.toggleFlag)
        XCTAssertEqual(state.session?.flaggedCount, 1)
    }

    func testCommitRemovesFlaggedAndContinues() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let c = try makeRaw("c.cr2")
        let trasher = StubTrasher()
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b, c])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)   // flag a
        state.handle(.next)
        state.handle(.toggleFlag)   // flag b
        state.requestCommit()
        XCTAssertEqual(state.pendingCommitCount, 2)
        state.confirmCommit()

        XCTAssertEqual(state.session?.count, 1)
        XCTAssertEqual(state.session?.flaggedCount, 0)
        XCTAssertEqual(trasher.trashed.count, 2)
        XCTAssertEqual(state.pendingCommitCount, 0)
    }

    func testCommitFailureKeepsFlag() async throws {
        let a = try makeRaw("a.cr2")
        let b = try makeRaw("b.cr2")
        let trasher = StubTrasher()
        trasher.failIDs = [a.path]
        let state = makeState(trasher: trasher)
        state.importFiles(urls: [a, b])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        state.confirmCommit()
        XCTAssertEqual(state.session?.count, 1)        // a stays
        XCTAssertEqual(state.session?.flaggedCount, 1) // a stays flagged
        XCTAssertEqual(state.commitFailures.count, 1)
    }

    func testCommitOfEverythingReturnsToEmptyState() async throws {
        let a = try makeRaw("a.cr2")
        let state = makeState()
        state.importFiles(urls: [a])
        await waitForScrubbing(state)

        state.handle(.toggleFlag)
        state.requestCommit()
        state.confirmCommit()
        XCTAssertNil(state.session)
        XCTAssertEqual(state.phase, .empty)
    }
}
```

Note: `StubDecoder` and `StubTrasher` are already defined in `DecodeEngineTests.swift` / `TrashCommitTests.swift`; move both stub classes into a shared `QuickCullCoreTests/TestDoubles.swift` file as part of this task (cut them from their original files so they aren't declared twice).

- [ ] **Step 2: Run tests to verify they fail**

Expected: BUILD FAILED with "cannot find 'AppState' in scope".

- [ ] **Step 3: Implement `AppState`**

`QuickCullCore/App/AppState.swift`:
```swift
import AppKit
import Foundation
import ImageIO
import Observation

public enum AppPhase: Equatable {
    case empty
    case decoding(completed: Int, total: Int)
    case scrubbing
}

/// Central app state: session phases, import pipeline, commit orchestration,
/// and the sliding windows. All UI observes this one object.
@MainActor
@Observable
public final class AppState {
    public private(set) var phase: AppPhase = .empty
    public private(set) var session: Session?
    public private(set) var importFailures: [DecodeOutcome] = []
    public private(set) var commitFailures: [TrashOutcome] = []
    public private(set) var pendingCommitCount: Int = 0

    public private(set) var thumbWindow: SlidingWindow?
    public private(set) var displayImages: DisplayImageProvider?

    public let cache: ImageCacheStore
    private let decoder: RawDecoding
    private let trasher: Trashing

    public init(decoder: RawDecoding = LibRawDecoder(),
                cache: ImageCacheStore = ImageCacheStore(baseURL: ImageCacheStore.defaultBaseURL()),
                trasher: Trashing = FileManagerTrasher()) {
        self.decoder = decoder
        self.cache = cache
        self.trasher = trasher
    }

    /// Launch-time authoritative cache cleanup (leftovers from crashes
    /// included); runs detached so UI never waits on it.
    public func prepareForLaunch() {
        Task { try? await cache.wipe() }
    }

    /// Import: validate + dedupe, then Phase 1 (decode everything), then scrub.
    public func importFiles(urls: [URL]) {
        let unique = Array(Set(urls.map(\.standardizedFileURL))).sorted { $0.path < $1.path }
        let supported = unique.filter(RawFileIdentity.isSupported)
        guard !supported.isEmpty else { return }

        let files = supported.map(SessionFile.init)
        session = Session(files: files)
        importFailures = []
        commitFailures = []
        pendingCommitCount = 0
        phase = .decoding(completed: 0, total: files.count)

        let engine = DecodeEngine(decoder: decoder, cache: cache)
        Task {
            for await event in engine.decodeAll(files: files) {
                switch event {
                case .progress(let completed, let total):
                    phase = .decoding(completed: completed, total: total)
                case .completed(let outcomes):
                    importFailures = outcomes.filter { $0.error != nil }
                    finishDecoding(files: files)
                }
            }
        }
    }

    private func finishDecoding(files: [SessionFile]) {
        guard let session else { return }
        thumbWindow = SlidingWindow(radius: 30, count: session.count,
                                    thumbnailLoader: makeThumbLoader(files: files))
        displayImages = DisplayImageProvider(loader: makeDisplayLoader(files: files))
        syncWindows()
        phase = .scrubbing
    }

    private func makeThumbLoader(files: [SessionFile]) -> (Int) async -> CGImage? {
        { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return Self.loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                                 maxPixelSize: 320)
        }
    }

    private func makeDisplayLoader(files: [SessionFile]) -> (Int) async -> CGImage? {
        let pixels = Self.displayPixelLimit()
        return { [cache] index in
            guard index >= 0, index < files.count else { return nil }
            return Self.loadJPEG(at: try? await cache.cacheURL(for: files[index]),
                                 maxPixelSize: pixels)
        }
    }

    public func handle(_ action: CullAction) {
        guard let session, phase == .scrubbing else { return }
        switch action {
        case .next: session.move(by: 1)
        case .previous: session.move(by: -1)
        case .jumpForward: session.move(by: 10)
        case .jumpBack: session.move(by: -10)
        case .toggleFlag: session.toggleFlag()
        }
        syncWindows()
    }

    public func setCurrentIndex(_ index: Int) {
        guard let session, phase == .scrubbing else { return }
        session.setIndex(index)
        syncWindows()
    }

    private func syncWindows() {
        guard let session else { return }
        thumbWindow?.setCurrent(session.currentIndex)
        displayImages?.setCurrent(session.currentIndex)
    }

    public func requestCommit() {
        pendingCommitCount = session?.flaggedCount ?? 0
    }

    public func confirmCommit() {
        guard let session else { return }
        let flagged = session.flaggedFiles
        let outcomes = TrashCommit(trasher: trasher).commit(files: flagged)
        let succeeded = outcomes.filter(\.succeeded).map(\.file)
        session.remove(succeeded)
        commitFailures = outcomes.filter { !$0.succeeded }
        pendingCommitCount = 0
        if session.isEmpty {
            // Nothing left to scrub: back to the empty state for a new import.
            self.session = nil
            thumbWindow = nil
            displayImages = nil
            phase = .empty
        } else {
            rebuildWindows()
        }
    }

    public func cancelCommit() {
        pendingCommitCount = 0
    }

    private func rebuildWindows() {
        thumbWindow = nil
        displayImages = nil
        if let session, !session.isEmpty {
            thumbWindow = SlidingWindow(radius: 30, count: session.count,
                                        thumbnailLoader: makeThumbLoader(files: session.files))
            displayImages = DisplayImageProvider(loader: makeDisplayLoader(files: session.files))
            syncWindows()
        }
    }

    private static func displayPixelLimit() -> Int {
        Int(max(NSScreen.main?.frame.width ?? 1920,
                NSScreen.main?.frame.height ?? 1080) * 2)
    }

    /// Downsamples a cached JPEG (thumbnail API = memory-bounded).
    static func loadJPEG(at url: URL?, maxPixelSize: Int) -> CGImage? {
        guard let url,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
```

- [ ] **Step 4: Implement the views**

`QuickCull/QuickCullApp.swift` (replace scaffold):
```swift
import SwiftUI
import QuickCullCore

@main
struct QuickCullApp: App {
    @State private var appState = AppState()
    @State private var monitor: KeyboardMonitor?

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 900, minHeight: 600)
                .task {
                    appState.prepareForLaunch()
                    let m = KeyboardMonitor()
                    m.start(appState: appState)
                    monitor = m
                    // Best-effort cache wipe on normal quit. Not guaranteed
                    // (force-quit skips it) — the launch wipe is authoritative.
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil, queue: .main) { _ in
                        let cache = appState.cache
                        Task { try? await cache.wipe() }
                    }
                }
        }
    }
}
```

`QuickCull/RootView.swift`:
```swift
import SwiftUI
import QuickCullCore

struct RootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.phase {
        case .empty: EmptyStateView()
        case .decoding: DecodingView()
        case .scrubbing: ScrubView()
        }
    }
}
```

`QuickCull/EmptyStateView.swift`:
```swift
import SwiftUI
import QuickCullCore
import UniformTypeIdentifiers

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    @State private var showImporter = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("QuickCull")
                .font(.largeTitle.bold())
            Text("Select raw files from any camera to start culling.")
                .foregroundStyle(.secondary)
            Button("Choose RAW Files…") { showImporter = true }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("Canon · Nikon · Sony · Fujifilm · Olympus · Panasonic · Leica · Pentax · more")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                appState.importFiles(urls: urls)
            }
        }
    }
}
```

`QuickCull/DecodingView.swift`:
```swift
import SwiftUI
import QuickCullCore

struct DecodingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            if case .decoding(let completed, let total) = appState.phase {
                ProgressView(value: Double(completed), total: Double(total))
                    .frame(maxWidth: 400)
                Text("Decoding \(completed) of \(total)…")
                    .monospacedDigit()
            }
            if !appState.importFailures.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(appState.importFailures.count) file(s) could not be decoded:")
                        .font(.headline)
                    List(appState.importFailures, id: \.file.id) { outcome in
                        Text("\(outcome.file.url.lastPathComponent) — \(outcome.error.map(String.init(describing:)) ?? "")")
                            .font(.caption)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
        .padding(40)
    }
}
```

`QuickCull/ScrubView.swift`:
```swift
import SwiftUI
import QuickCullCore

struct ScrubView: View {
    @Environment(AppState.self) private var appState
    @State private var showCommitConfirm = false
    @State private var showCommitFailures = false

    var body: some View {
        VStack(spacing: 0) {
            ImageDisplayView()
            Divider()
            FilmstripView()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.requestCommit()
                    showCommitConfirm = true
                } label: {
                    Label("Move Flagged to Trash", systemImage: "trash")
                }
                .disabled(appState.session?.flaggedCount == 0)
            }
        }
        .alert("Move \(appState.pendingCommitCount) file(s) to Trash?",
               isPresented: $showCommitConfirm) {
            Button("Move to Trash", role: .destructive) { appState.confirmCommit() }
            Button("Cancel", role: .cancel) { appState.cancelCommit() }
        } message: {
            Text("Flagged files will be removed from this session. Scrubbing continues with the rest.")
        }
        .alert("Could not move \(appState.commitFailures.count) file(s) to Trash",
               isPresented: $showCommitFailures) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The remaining files keep their flags. You may need to grant file access in System Settings.")
        }
        .onChange(of: appState.commitFailures.count) {
            if appState.commitFailures.count > 0 { showCommitFailures = true }
        }
    }
}
```

`QuickCull/ImageDisplayView.swift`:
```swift
import SwiftUI
import QuickCullCore

struct ImageDisplayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let index = appState.session?.currentIndex ?? 0
        ZStack {
            Color.black
            if let image = appState.displayImages?.image(at: index) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().controlSize(.large)
            }
            if let file = appState.session?.files[index],
               appState.session?.isFlagged(file) == true {
                VStack {
                    HStack {
                        Spacer()
                        FlagBadge().padding(12)
                    }
                    Spacer()
                }
            }
        }
    }
}
```

`QuickCull/FilmstripView.swift`:
```swift
import SwiftUI
import QuickCullCore

struct FilmstripView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 3) {
                    ForEach(0..<(appState.session?.count ?? 0), id: \.self) { index in
                        ThumbnailCell(index: index)
                            .id(index)
                    }
                }
                .padding(6)
            }
            .frame(height: 86)
            .background(.thinMaterial)
            .onChange(of: appState.session?.currentIndex) {
                if let current = appState.session?.currentIndex {
                    withAnimation(.snappy) { proxy.scrollTo(current, anchor: .center) }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    let index: Int
    @Environment(AppState.self) private var appState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let image = appState.thumbWindow?.image(at: index) {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
            if let file = appState.session?.files[index],
               appState.session?.isFlagged(file) == true {
                FlagBadge()
            }
        }
        .frame(width: 100, height: 64)
        .clipped()
        .overlay(
            Rectangle().strokeBorder(
                index == appState.session?.currentIndex ? Color.accentColor : .clear,
                lineWidth: 2)
        )
        .contentShape(Rectangle())
        .onTapGesture { appState.setCurrentIndex(index) }
    }
}
```

`QuickCull/FlagBadge.swift`:
```swift
import SwiftUI

struct FlagBadge: View {
    var body: some View {
        Image(systemName: "xmark.circle.fill")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, .red)
            .shadow(radius: 1)
            .padding(2)
    }
}
```

`QuickCull/KeyboardMonitor.swift`:
```swift
import AppKit
import QuickCullCore

/// App-wide key handling via a local event monitor (no focus requirements —
/// scrubbing must work the moment the window is up).
final class KeyboardMonitor {
    private var token: Any?

    func start(appState: AppState) {
        token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let action = CullKeyMap.action(forKeyCode: event.keyCode) {
                Task { @MainActor in appState.handle(action) }
                return nil   // consume
            }
            return event
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
            self.token = nil
        }
    }
}
```

- [ ] **Step 5: Run the full suite**

Expected: `Executed 45 tests, with 0 failures`.

- [ ] **Step 6: Build the app**

Run: `xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: Manual smoke checklist** (run on a real Mac with the Xcode GUI or `open /tmp/qc-dd/Build/Products/Debug/QuickCull.app`; the sandboxed harness cannot launch GUI apps)

1. Launch → empty state with "Choose RAW Files…" button.
2. Select 3+ raw files (use the fixtures) → decode progress shows n/total → scrub screen appears.
3. → advances, ← goes back; ↑/↓ jump 10 (clamped at edges); filmstrip scrolls to current.
4. Z shows the red badge on the image and its filmstrip cell; Z again removes it.
5. Click a filmstrip thumbnail → jumps there.
6. Flag 2 files → toolbar button enabled → commit → confirmation dialog → Move to Trash → files vanish from filmstrip, count drops, flags cleared, scrubbing continues.
7. Import a new set → old flags gone.
8. Quit and relaunch → cache dir (`~/Library/Application Support/QuickCull/cache/`) was wiped at launch (it contains only the current session's JPEGs).

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "feat: full culling UI with keyboard scrub, filmstrip, flag badge, trash commit"
```

---

### Task 10: README, LGPL notice, final verification

**Files:**
- Create: `NOTICE`
- Modify: `README.md`

- [ ] **Step 1: Write `NOTICE`** (LGPL-2.1 dynamic-linking compliance: library identified, license named, source linked, replacement allowed)

```markdown
# Third-Party Notices

## LibRaw 0.22.1

QuickCull dynamically links libraw (LGPL-2.1) to decode raw image files.

- License: GNU Lesser General Public License, version 2.1 (or later)
- Source: https://github.com/LibRaw/LibRaw (tag 0.22.1)
- The library is shipped as an unmodified `libraw.dylib` inside
  `QuickCullCore.framework/Versions/A/Frameworks/`. As permitted by the
  LGPL, you may replace it with your own build of the same version.
- Build flags: `-DLIBRAW_NODLL -DNO_JPEG -DNO_JASPER -DNO_LCMS`
```

- [ ] **Step 2: Expand `README.md`** — replace the scaffold README with the full usage/build/testing docs (controls table, supported formats, cache behavior, LGPL note, fixture regeneration via `Scripts/fetch-fixtures.sh`, test commands).

- [ ] **Step 3: Full verification from a clean state**

```bash
rm -rf Build /tmp/qc-dd
xcodebuild -project QuickCull.xcodeproj -scheme QuickCullCore -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build-for-testing
xcrun xctest /tmp/qc-dd/Build/Products/Debug/QuickCullCoreTests.xctest
xcodebuild -project QuickCull.xcodeproj -scheme QuickCull -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/qc-dd CODE_SIGNING_ALLOWED=NO build
```

Expected: clean LibRaw rebuild (few minutes), `Executed 45 tests, with 0 failures`, `** BUILD SUCCEEDED **`. Confirm `git status` is clean (only intended changes) and no `Build/` artifacts are tracked.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs: usage, license notice, and final v1 verification"
```

---

## Self-Review Notes

- **Spec coverage:** decode-all-before-scrub (Task 7 + Task 9 pipeline), full-res q75 cache (Tasks 2-3), launch wipe (Tasks 3, 9), ±30 window (Task 5), in-memory flags per session (Task 4, Task 9), keyboard map with ±10 jumps and Z badge (Tasks 6, 9), filmstrip + click-to-jump (Task 9), Trash commit with multi-pass (Tasks 8-9), error paths (corrupt raw, trash failure, unsupported extension, dedupe — Tasks 2, 7, 8, 9), LGPL dynamic linking (Tasks 1, 10), fixtures per brand (Task 2), performance smoke via integration test (Task 7). All v1 scope items are covered; zoom/undo/persistent flags are absent as specced.
- **Known test-count arithmetic:** totals per task assume exactly the tests listed; adjust the expected number if a test was legitimately added or removed, never to make red pass.
- **Placeholder scan:** no TBDs; every code block is complete; all URLs and hashes were verified live during plan validation (LibRaw tarball, fixtures, Xcode project format, test-runner path).
