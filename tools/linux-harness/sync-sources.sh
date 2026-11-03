#!/bin/bash
# Copies the Foundation-only app sources into Sources/WispCore/.
# App sources are never edited for the harness; platform gaps are covered
# by HarnessShims.swift plus ONE documented line-drop (see below).
# Run from this directory: ./sync-sources.sh
set -euo pipefail
cd "$(dirname "$0")"
APP=../../Wisp
DEST=Sources/WispCore

FILES=(
  # LLM (all 12)
  LLM/SSEParser.swift
  LLM/OpenAICompatibleProvider.swift
  LLM/PromptBuilder.swift
  LLM/ChatProvider.swift
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
  Listening/ListeningTranscript.swift
  Listening/ONNXModelInfo.swift
  # Support
  Support/AppSettings.swift
)

for f in "${FILES[@]}"; do
  cp "$APP/$f" "$DEST/$(basename "$f")"
done
echo "synced ${#FILES[@]} files"

# ONE documented line-drop: OpenAICompatibleProvider sets
# `config.waitsForConnectivity = false`. On Linux that property is
# get-only and always false, so the assignment cannot compile and
# dropping it preserves the exact semantics. The macOS source is
# untouched; only this build-artifact copy differs, by this one line.
sed -i '/config\.waitsForConnectivity = false/d' "$DEST/OpenAICompatibleProvider.swift"
grep -q "waitsForConnectivity" "$APP/LLM/OpenAICompatibleProvider.swift" \
  || { echo "sync: waitsForConnectivity vanished upstream — update this script"; exit 1; }

# ContextCapture.truncate family: mechanically extracted verbatim.
python3 extract-context-capture.py

# Drift guard for the one mirrored constant in HarnessShims.swift.
grep -q "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-int8-2024-07-17" \
  "$APP/Listening/LocalSpeechCatalog.swift" \
  || { echo "sync: legacySenseVoiceID changed upstream — update HarnessShims.swift"; exit 1; }
echo "sync complete"
