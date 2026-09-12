"""Validate cursor recordings with positive controls; preserve historical parked-mode reports."""
import copy
import json
import re
import sys


def validate_single_cursor(report):
    issues = []
    activation = report.get("nonKeyOnly", False)
    expected = {"off", "inactive", "on", "restored"} if activation else {"off", "on", "restored"}
    rows = {row.get("mode"): row for row in report.get("modes", [])}
    if set(rows) != expected or len(report.get("modes", [])) != len(expected):
        return {"verdict": "INCONCLUSIVE", "issues": ["Missing or duplicate single-cursor controls"]}
    if report.get("showsCursor") is not True or report.get("recorderExcludesWindows") is not False:
        issues.append("Recorder must include system cursor and exclude no windows")
    transitions = report.get("transitionFrames", [])
    if len(transitions) < 10:
        issues.append("Missing continuous mode-transition frames")
    if any(f.get("pointerComponents", 2) > 1 or f.get("cyan", 0) <= 0 or f.get("magenta", 1) != 0 for f in transitions):
        issues.append("Continuous transitions show duplicate cursor components or missing/private controls")
    if not any(f.get("pointerComponents") == 1 for f in transitions):
        issues.append("Continuous transitions lack a visible-cursor positive control")
    for mode, row in rows.items():
        locked = mode == "on"
        frames = row.get("sckFrames", [])
        if len(frames) < 3:
            issues.append(f"{mode}: insufficient video frames")
        if any(f.get("cyan", 0) <= 0 or f.get("magenta", 1) != 0 for f in frames):
            issues.append(f"{mode}: missing background control or private-content leak")
        if locked:
            if any(f.get("dark", 1) != 0 or f.get("cyan") != f.get("total") for f in frames):
                issues.append("on: system/extra cursor or recorder click overlay visible beside the private local pointer")
        else:
            if any(f.get("dark", 0) <= 0 for f in frames):
                issues.append(f"{mode}: system-pointer positive control missing")
            bounds = {tuple(f.get(k) for k in ("darkMinX", "darkMinY", "darkMaxX", "darkMaxY")) for f in frames}
            if len(bounds) < 2:
                issues.append(f"{mode}: system pointer did not move")
        video = row.get("systemVideo", {})
        if row.get("systemVideoExit") != 0 or video.get("cyan", 0) <= 0 or video.get("magenta", 1) != 0:
            issues.append(f"{mode}: missing system-video controls")
        elif (locked and video.get("dark", 1) != 0) or (not locked and video.get("dark", 0) <= 0):
            issues.append(f"{mode}: unexpected system-video cursor")
        state = row.get("fixture", {})
        if state.get("active") is not (mode != "inactive"):
            issues.append(f"{mode}: wrong application activation state")
        if mode == "inactive" and state.get("key") is not False:
            issues.append("inactive: fixture still has key focus")
        if state.get("localVisible") is not locked or state.get("replacing") is not locked or state.get("cursorWindowCount") != int(locked):
            issues.append(f"{mode}: unexpected local pointer count/state")
        if state.get("cursorSamples", 0) < 10 or state.get("duplicateOverlaySamples", -1) != 0:
            issues.append(f"{mode}: duplicate local arrows or missing local samples")
        if locked and state.get("parentAttached") is not True:
            issues.append("on: private arrow detached from its owner")
    if not activation:
        gestures = report.get("interactionFrames", {})
        expected_gestures = {"button", "typing", "text-selection", "scrolling", "menu-selection", "drag-resize"}
        if set(gestures) != expected_gestures:
            issues.append("Missing interaction capture stages")
        for gesture, frames in gestures.items():
            if len(frames) < 2 or any(f.get("dark", 1) != 0 or f.get("magenta", 1) != 0 or f.get("cyan", 0) <= 0 or f.get("cyan") != f.get("total") for f in frames):
                issues.append(f"{gesture}: visible interaction pixels or insufficient capture controls")
        if report.get("menuSelection", {}).get("popupSelection") != 1:
            issues.append("Native popup selection did not change to the second item")
        local = rows["on"].get("fixture", {})
        interaction = report.get("nativeInteraction", {})
        selection = report.get("textSelection", {})
        scrolling = report.get("scrolling", {})
        if interaction.get("clicks") != 1 or interaction.get("text") != "cursor test":
            issues.append("Native clicking/typing failed")
        if selection.get("selectionLength") != 11 or scrolling.get("scrollY", 0) <= 0:
            issues.append("Native selection/scrolling failed")
        before = re.findall(r"-?\d+(?:\.\d+)?", local.get("windowFrame", ""))
        after = re.findall(r"-?\d+(?:\.\d+)?", interaction.get("windowFrame", ""))
        if len(before) != 4 or len(after) != 4 or before[:2] == after[:2] or before[2:] == after[2:]:
            issues.append("Native dragging/resizing failed")
        for name, state in [("selection", selection), ("scrolling", scrolling), ("interaction", interaction)]:
            if not all(state.get(k) for k in ("arrow", "active", "localVisible", "replacing", "parentAttached")) or state.get("cursorWindowCount") != 1:
                issues.append(f"{name}: native operation lost the single private pointer")
            if state.get("duplicateOverlaySamples", -1) != 0:
                issues.append(f"{name}: duplicate local arrow sampled")
        outside = report.get("afterLeaving", {})
        if outside.get("replacing") is not False or outside.get("localVisible") is not False or outside.get("cursorWindowCount") != 0 or outside.get("parentAttached") is not False:
            issues.append("Leaving Wisp did not remove/detach the private arrow")
        restored = report.get("afterMenuRestored", {})
        shot = report.get("afterMenuScreenshot", {})
        if restored.get("replacing") is not False or restored.get("cursorWindowCount") != 0 or shot.get("pointerComponents") != 1 or shot.get("cyan", 0) <= 0 or shot.get("magenta", 1) != 0:
            issues.append("System cursor failed to restore after native menu interaction")
    return {"verdict": "PASS_SINGLE_CURSOR" if not issues else "FAIL", "issues": issues,
            "transitionFrames": len(transitions),
            "interactionFrames": {name: len(frames) for name, frames in report.get("interactionFrames", {}).items()},
            "frames": {mode: len(row.get("sckFrames", [])) for mode, row in rows.items()},
            "localSamples": {mode: row.get("fixture", {}).get("cursorSamples", 0) for mode, row in rows.items()},
            "scope": "One private local arrow; independent sampled video omits system and shared arrows in lock mode. Recorder overlays remain separate."}


def validate_activation(report):
    issues = []
    rows = {row.get("mode"): row for row in report.get("modes", [])}
    if set(rows) != {"off", "inactive", "on", "restored"}:
        return {"verdict": "INCONCLUSIVE", "issues": ["Missing activation controls"]}
    if report.get("showsCursor") is not True or report.get("recorderExcludesWindows") is not False:
        issues.append("Recorder must include cursor and exclude no windows")
    counts = {}
    for mode, row in rows.items():
        frames = row.get("sckFrames", [])
        counts[mode] = len(frames)
        if len(frames) < 3 or any(f.get("dark", 0) <= 0 or f.get("cyan", 0) <= 0 or f.get("magenta", 1) != 0 for f in frames):
            issues.append(f"{mode}: missing frames/positive controls or private-content leak")
        positions = {tuple(f.get(k) for k in ("darkMinX", "darkMinY", "darkMaxX", "darkMaxY")) for f in frames}
        if (mode == "on" and len(positions) != 1) or (mode != "on" and len(positions) < 2):
            issues.append(f"{mode}: unexpected captured pointer motion")
        state = row.get("fixture", {})
        if state.get("replacing") is not (mode == "on") or state.get("localVisible") is not (mode == "on"):
            issues.append(f"{mode}: unexpected local cursor state")
        if state.get("active") is not (mode != "inactive"):
            issues.append(f"{mode}: incorrect foreground control")
        if mode == "inactive" and state.get("key") is not False:
            issues.append("inactive: panel still has key focus")
    return {"verdict": "PASS_SAMPLED_ACTIVATION" if not issues else "FAIL", "issues": issues, "frames": counts,
            "scope": "Background hover keeps the real pointer; an explicit click activates the fixture before locking."}


def validate(report):
    if report.get("presentation") == "single-private":
        return validate_single_cursor(report)
    if report.get("nonKeyOnly"):
        return validate_activation(report)
    issues = []
    rows = {row.get("mode"): row for row in report.get("modes", [])}
    if set(rows) != {"off", "on", "restored"}:
        return {"verdict": "INCONCLUSIVE", "issues": ["Missing off/on/restored controls"]}
    if report.get("showsCursor") is not True or report.get("recorderExcludesWindows") is not False:
        issues.append("Recorder must include cursor and exclude no windows")
    frame_counts = {}
    for mode, row in rows.items():
        frames = row.get("sckFrames", [])
        frame_counts[mode] = len(frames)
        if len(frames) < 3:
            issues.append(f"{mode}: insufficient video frames")
        if any(frame.get("dark", 0) <= 0 or frame.get("cyan", 0) <= 0 for frame in frames):
            issues.append(f"{mode}: missing pointer or background control")
        if any(frame.get("magenta", 1) != 0 for frame in frames):
            issues.append(f"{mode}: private fixture content detected")
        positions = {tuple(frame.get(key) for key in ("darkMinX", "darkMinY", "darkMaxX", "darkMaxY"))
                     for frame in frames}
        if mode == "on" and len(positions) != 1:
            issues.append("on: recorder click overlay or pointer motion detected" if report.get("showMouseClicks")
                          else "on: captured pointer moved")
        if mode != "on" and len(positions) < 2:
            issues.append(f"{mode}: moving-pointer positive control absent")
        video = row.get("systemVideo", {})
        if row.get("systemVideoExit") != 0 or video.get("dark", 0) <= 0 or video.get("cyan", 0) <= 0 or video.get("magenta", 1) != 0:
            issues.append(f"{mode}: system video sample lacks a protected-content/pointer control")
    local = rows["on"].get("fixture", {})
    if not local.get("localVisible") or not local.get("replacing") or local.get("cursorFrame") == local.get("parkedFrame"):
        issues.append("Local moving pointer was not observed separately from parked pointer")
    interaction = report.get("nativeInteraction", {})
    selection = report.get("textSelection", {})
    scrolling = report.get("scrolling", {})
    if interaction.get("clicks") != 1 or interaction.get("text") != "cursor test":
        issues.append("Native clicking/typing failed")
    if selection.get("selectionLength") != 11 or scrolling.get("scrollY", 0) <= 0:
        issues.append("Native selection/scrolling failed")
    def window_frame(state):
        return re.findall(r"-?\d+(?:\.\d+)?", state.get("windowFrame", ""))

    before, after = window_frame(local), window_frame(interaction)
    if len(before) != 4 or len(after) != 4 or before[:2] == after[:2] or before[2:] == after[2:]:
        issues.append("Native interaction must change both window position and size")
    if not all(state.get("arrow") for state in [local, interaction, selection, scrolling]):
        issues.append("Non-arrow artwork was observed")
    if not all(state.get("active") and state.get("localVisible") and state.get("replacing")
               for state in [local, interaction, selection, scrolling]):
        issues.append("Fixture lost focus or its local pointer during native interaction")
    outside = report.get("afterLeaving", {})
    if outside.get("replacing") is not False or outside.get("localVisible") is not False:
        issues.append("Local cursor not restored after leaving Wisp")
    return {
        "verdict": "PASS_SAMPLED_VIDEO" if not issues else "FAIL",
        "issues": issues,
        "frames": frame_counts,
        "scope": "Synthetic SCK continuous video plus one system-video sample per mode. No third-party receiver guarantee.",
        "staticScreenshotPointerPresent": {
            mode: row.get("sckScreenshot", {}).get("dark", 0) > 0 for mode, row in rows.items()
        },
        "fixtureCPUPercent": {
            mode: round(row["fixture"].get("phaseCPUSeconds", 0) / max(row["fixture"].get("phaseSeconds", 1), .001) * 100, 2)
            for mode, row in rows.items() if "phaseCPUSeconds" in row.get("fixture", {})
        },
    }


if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        report = json.load(source)
    result = validate(report)
    if "--feedback" in sys.argv[2:]:
        from pathlib import Path
        with open(Path(sys.argv[1]).with_name("feedback-result.json")) as source:
            samples = json.load(source).get("samples", [])
        expected = {(mode, style) for mode in ("feedback-off", "feedback-on") for style in ("press", "icon", "plain")}
        failures = []
        if len(samples) != 6 or {(s.get("mode"), s.get("style")) for s in samples} != expected:
            failures.append("Missing button feedback controls")
        for sample in samples:
            same = sample.get("before") == sample.get("held")
            if not sample.get("before") or not sample.get("held") or same != (sample.get("mode") == "feedback-on"):
                failures.append(f"{sample.get('mode')}/{sample.get('style')}: unexpected held-button pixels")
            if sample.get("afterClicks", 0) - sample.get("beforeClicks", 0) != 1:
                failures.append(f"{sample.get('style')}: action did not fire exactly once")
        result["buttonFeedback"] = {"samples": len(samples), "issues": failures}
        if failures:
            result["verdict"] = "FAIL"
            result["issues"].extend(failures)
    if "--self-test" in sys.argv[2:]:
        single = report.get("presentation") == "single-private"
        defects = (["blank_control", "extra_cursor", "missing", "leak", "duplicate_local", "local_hidden", "no_resize", "transition_duplicate", "interaction_leak", "colored_leak", "stuck_hidden"] if single
                   else ["blank", "moving", "missing", "leak", "reshaped", "local_hidden", "no_resize"])
        for defect in defects:
            broken = copy.deepcopy(report)
            on = next(row for row in broken["modes"] if row["mode"] == "on")
            if defect == "colored_leak":
                broken["interactionFrames"]["text-selection"][0]["cyan"] -= 1
            elif defect == "interaction_leak":
                broken["interactionFrames"]["typing"][0]["dark"] = 1
            elif defect == "stuck_hidden":
                broken["afterMenuScreenshot"]["pointerComponents"] = 0
            elif defect == "transition_duplicate":
                broken["transitionFrames"][0]["pointerComponents"] = 2
            elif defect == "blank_control":
                broken["modes"][0]["sckFrames"][0]["dark"] = 0
            elif defect == "extra_cursor":
                on["sckFrames"][0]["dark"] = 1
            elif defect == "duplicate_local":
                on["fixture"]["duplicateOverlaySamples"] = 1
            elif defect == "blank":
                for frame in on["sckFrames"]:
                    frame["dark"] = 0
            elif defect == "moving":
                on["sckFrames"][0]["darkMinX"] += 10
            elif defect == "missing":
                on["sckFrames"] = []
            elif defect == "leak":
                on["sckFrames"][0]["magenta"] = 1
            elif defect == "reshaped":
                on["sckFrames"][0]["darkMaxX"] += 10
            elif defect == "local_hidden":
                broken["textSelection"]["localVisible"] = False
            else:
                broken["nativeInteraction"]["windowFrame"] = on["fixture"]["windowFrame"]
            assert not validate(broken)["verdict"].startswith("PASS_"), defect
        result["validatorCounterexamples"] = f"{len(defects)}/{len(defects)} rejected"
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["verdict"] in {"PASS_SAMPLED_VIDEO", "PASS_SAMPLED_ACTIVATION", "PASS_SINGLE_CURSOR"} else 1)
