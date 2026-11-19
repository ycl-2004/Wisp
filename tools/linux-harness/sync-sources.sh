#!/bin/bash
# Copies the Foundation-only app sources into Sources/Wisp/ and the tests
# that exercise them into Tests/WispTests/. Both are copies of the one real
# source (../../Wisp and ../../WispTests): nothing here is edited by hand
# except HarnessShims.swift. Platform gaps are covered by HarnessShims.swift
# plus ONE documented line-drop (see below).
# Run from this directory: ./sync-sources.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=../../Wisp
DEST=Sources/Wisp
TESTS=../../WispTests
TEST_DEST=Tests/WispTests

FILES=(
  # LLM (all 13)
  LLM/SSEParser.swift
  LLM/OpenAICompatibleProvider.swift
  LLM/PromptBuilder.swift
  LLM/ChatProvider.swift
  LLM/CLIRunBox.swift
  LLM/CloudProvider.swift
  LLM/ClaudeCodeCLIProvider.swift
  LLM/CodexCLIProvider.swift
  LLM/AgyCLIProvider.swift
  LLM/ModelCatalog.swift
  LLM/ProviderKind.swift
  LLM/ResponsePolicy.swift
  LLM/OllamaSupport.swift
  # Capture (Foundation-only subset)
  Capture/BrowserTextExtractor.swift
  Capture/ChromeProfileInspector.swift
  Capture/ContextPacket.swift
  Capture/PageTextScript.swift
  # Store
  Store/Conversation.swift
  Store/ConversationStore.swift
  # Listening (Foundation-only subset)
  Listening/CaptionTypes.swift
  # Support
  Support/AppSettings.swift
  Support/OnboardingReadiness.swift
)

# Start clean: a copy of a file renamed or removed upstream would otherwise linger and still compile.
find "$DEST" -name '*.swift' ! -name HarnessShims.swift -delete
for f in "${FILES[@]}"; do
  cp "$APP/$f" "$DEST/$(basename "$f")"
done
echo "synced ${#FILES[@]} files"

# Test files whose every subject is in the closure above. They are copied
# verbatim — WispTests is the only place a test is written or edited. A test
# file that needs AppKit/SwiftUI stays macOS-only by not being
# listed; split such a file rather than adding #if branches to it.
TEST_FILES=(
  FuzzSupport.swift
  MainActorBridge.swift
  StoreFixture.swift
  CaptureScopeTests.swift
  ClaudeCodeCLIProviderTests.swift
  CLIJSONLinesFuzzTests.swift
  CLIJSONLinesTests.swift
  CLITempSweepTests.swift
  ConversationAcceptanceTests.swift
  ConversationStoreMatrixTests.swift
  DrainBufferBoundaryTests.swift
  DrainBufferTests.swift
  CaptionBufferTests.swift
  OnboardingReadinessTests.swift
  ProviderSharedTests.swift
  ResponseModeTests.swift
  Round4AppleScriptSinkTests.swift
  Round4CappedBodyTests.swift
  Round4DebugDumpGateTests.swift
  Round4OllamaProbeTests.swift
  Round4PipeDeadlineTests.swift
  Round4SettingsClampTests.swift
  Round4SSEDecodeTests.swift
  Round4StoreGuardTests.swift
  Round5WipeTests.swift
  Round6CLIProviderTests.swift
  Round6FakeCloudTests.swift
  Round6RealOllamaTests.swift
  Round6RealServerTests.swift
  SSEFuzzTests.swift
  StreamGuardTests.swift
  TruncationCharacterizationTests.swift
)

rm -rf "$TEST_DEST"
mkdir -p "$TEST_DEST"
for f in "${TEST_FILES[@]}"; do
  cp "$TESTS/$f" "$TEST_DEST/$f"
done
echo "synced ${#TEST_FILES[@]} test files"

# ONE documented line-drop: OpenAICompatibleProvider sets
# `config.waitsForConnectivity = false`. On Linux that property is
# get-only and always false, so the assignment cannot compile and
# dropping it preserves the exact semantics. The macOS source is
# untouched; only this build-artifact copy differs, by this one line.
# `-i.bak` + rm is the spelling both GNU sed (Linux) and BSD sed (macOS) accept.
sed -i.bak '/config\.waitsForConnectivity = false/d' "$DEST/OpenAICompatibleProvider.swift"
rm -f "$DEST/OpenAICompatibleProvider.swift.bak"
grep -q "waitsForConnectivity" "$APP/LLM/OpenAICompatibleProvider.swift" \
  || { echo "sync: waitsForConnectivity vanished upstream — update this script"; exit 1; }

# ContextCapture.truncate family: mechanically extracted verbatim.
python3 extract-context-capture.py

echo "sync complete"
