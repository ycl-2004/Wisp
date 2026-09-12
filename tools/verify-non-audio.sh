#!/bin/bash
# Repeatable non-audio verification. Native mode temporarily controls the mouse.
# No installed app replacement, real model request, or Claude CLI invocation.
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-unit}"
case "$mode" in unit|native|release) ;; *) echo 'Usage: bash tools/verify-non-audio.sh unit|native|release' >&2; exit 2;; esac
audit_dir="$(mktemp -d /private/tmp/wisp-nonaudio.XXXXXX)"
echo "Evidence: $audit_dir"

if [[ "$mode" == unit ]]; then
    xcodebuild test -project Wisp.xcodeproj -scheme Wisp -destination 'platform=macOS' \
        -skip-testing:WispTests/LocalSpeechTests -skip-testing:WispTests/ListeningTests \
        CODE_SIGNING_ALLOWED=NO -resultBundlePath "$audit_dir/unit.xcresult" > "$audit_dir/unit.log" 2>&1
    # These general window tests currently live in ListeningTests; select only them.
    window_tests=(
        testMenuRemovalRecoveryPreservesExplicitOptOutAndIsBounded
        testOpeningHistoryExpandsCollapsedPanel
        testLongHeaderFitsNarrowPanelInBothLanguagesAndAppearances
        testPanelHostingDoesNotImposeContentDrivenResizeLimits
        testHeaderTitleAreaDragsTheWindowWhileButtonsKeepTheirClicks
        testResizeGrabsOnlyTheEdgesAndWidensAtTheCorners
        testPanelResizeCursorFollowsPrivacySwitch
        testResizeKeepsTheOppositeEdgeFixedAndObeysWindowLimits
        testResizeOverlayInterceptsEdgesAndLetsContentKeepItsClicks
        testResizeOverlayDoesNotStealTitleEdgeDrags
    )
    selection=()
    for name in "${window_tests[@]}"; do selection+=("-only-testing:WispTests/ListeningTests/$name"); done
    xcodebuild test -project Wisp.xcodeproj -scheme Wisp -destination 'platform=macOS' \
        "${selection[@]}" CODE_SIGNING_ALLOWED=NO \
        -resultBundlePath "$audit_dir/window.xcresult" > "$audit_dir/window.log" 2>&1
    python3 tools/test-install-local.py > "$audit_dir/installer.log"
    node tools/screen-privacy/BrowserIntegrityAudit.cjs > "$audit_dir/browser-integrity.json"
    bash -n tools/install-local.sh tools/verify-non-audio.sh
    plutil -lint Wisp/App/Info.plist Wisp.entitlements
    jq empty Wisp/Resources/Localizable.xcstrings
    git diff --check
    echo 'PASS: selected non-audio tests and structural checks. See logs for counts.'
elif [[ "$mode" == native ]]; then
    echo 'Synthetic windows and mouse gestures will run; leave the desktop idle until completion.'
    swiftc -O -parse-as-library -module-cache-path "$audit_dir/cache" \
        Wisp/Support/ScreenPrivacy.swift Wisp/Support/LocalCursorController.swift \
        Wisp/UI/DesignKit.swift Wisp/UI/PanelResize.swift tools/screen-privacy/LocalCursorProbe.swift \
        -o "$audit_dir/cursor-probe"
    "$audit_dir/cursor-probe" run "$audit_dir/cursor" > "$audit_dir/cursor.log" 2>&1
    python3 tools/screen-privacy/validate-cursor.py "$audit_dir/cursor/result.json" --self-test > "$audit_dir/cursor-summary.json"
    swiftc -parse-as-library -module-cache-path "$audit_dir/cache" \
        Wisp/Support/ScreenPrivacy.swift tools/screen-privacy/CaptureMatrixProbe.swift -o "$audit_dir/matrix-probe"
    "$audit_dir/matrix-probe" visible "$audit_dir/matrix-visible.json" > "$audit_dir/matrix-visible.log" 2>&1
    "$audit_dir/matrix-probe" hidden "$audit_dir/matrix-hidden.json" > "$audit_dir/matrix-hidden.log" 2>&1
    python3 tools/screen-privacy/validate-matrix.py "$audit_dir/matrix-visible.json" "$audit_dir/matrix-hidden.json" > "$audit_dir/matrix-summary.json"
    echo 'PASS: sampled native cursor/video and window matrix. Static screenshots and third-party receivers have separate limits.'
else
    xcodebuild build -project Wisp.xcodeproj -scheme Wisp -configuration Release \
        -arch arm64 -arch x86_64 ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- \
        CODE_SIGNING_REQUIRED=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
        SYMROOT="$audit_dir/products" OBJROOT="$audit_dir/objects" > "$audit_dir/release.log" 2>&1
    candidate="$audit_dir/products/Release/Wisp.app"
    lipo -archs "$candidate/Contents/MacOS/Wisp"
    codesign --verify --deep --strict "$candidate"
    codesign -d --entitlements :- "$candidate" > "$audit_dir/entitlements.plist" 2> "$audit_dir/signature.log"
    if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$audit_dir/entitlements.plist" >/dev/null 2>&1; then
        echo 'FAIL: Release includes debugger entitlement' >&2; exit 1
    fi
    echo "PASS: Release candidate at $candidate (not installed or published)"
fi
