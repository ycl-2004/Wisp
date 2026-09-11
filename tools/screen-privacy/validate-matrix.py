#!/usr/bin/env python3
"""Validate paired CaptureMatrixProbe results. A missing/blank control never passes.

Exit 0: sampled paths passed, 1: target marker leaked, 2: inconclusive/error.
Mission Control needs separately localized thumbnail controls and is not certified here.
"""
import json
import sys
from pathlib import Path

TARGETS = ('panel', 'settings', 'video')
PATHS = ('exclude-no-windows', 'include-all-applications',
         'exclude-no-applications', 'include-all-windows')


def validate(visible, hidden):
    issues, leaks = [], []
    samples = 0

    def check(rows, mode, path):
        nonlocal samples
        if not rows:
            issues.append(f'{mode}/{path}: no frames')
            return
        for index, row in enumerate(rows):
            samples += 1
            if row.get('control', {}).get('cyan', 0) < 0.8:
                issues.append(f'{mode}/{path}/{index}: visible control missing')
            for name in TARGETS:
                marker = row.get(name, {}).get('magenta')
                if not isinstance(marker, (int, float)) or not 0 <= marker <= 1:
                    issues.append(f'{mode}/{path}/{index}/{name}: missing or invalid measurement')
                elif mode == 'visible' and marker < 0.8:
                    issues.append(f'{mode}/{path}/{index}/{name}: paired target not visible')
                elif mode == 'hidden' and marker > 0:
                    leaks.append(f'{mode}/{path}/{index}/{name}: marker fraction {marker}')

    if visible.get('mode') != 'visible' or hidden.get('mode') != 'hidden':
        issues.append('Wrong A/B modes')
    if visible.get('os') != hidden.get('os'):
        issues.append('OS differs across A/B pair')
    for mode, data in [('visible', visible), ('hidden', hidden)]:
        if data.get('displayCount') != 1 or not data.get('separateProcesses'):
            issues.append(f'{mode}: unsupported display/process setup')
        for path in PATHS:
            shot = [s for s in data.get('shots', []) if s.get('path') == path]
            stream = [s for s in data.get('streams', []) if s.get('path') == path]
            if len(shot) != 1 or len(stream) != 1:
                issues.append(f'{mode}/{path}: missing or duplicate path')
                continue
            if 'error' in shot[0]:
                issues.append(f'{mode}/{path}: screenshot error')
            check([shot[0].get('targets', {})], mode, path + '/screenshot')
            rows = stream[0].get('frames', [])
            if stream[0].get('completeFrames') != len(rows) or len(rows) < 3:
                issues.append(f'{mode}/{path}: insufficient/mismatched complete frame count')
            check(rows, mode, path + '/stream')
        movie = data.get('systemMovie', {})
        if movie.get('exitStatus') != 0 or 'error' in movie or len(movie.get('sampledFrames', [])) < 3:
            issues.append(f'{mode}/system-movie: unsuccessful or insufficient capture')
        check(movie.get('sampledFrames', []), mode, 'system-movie')
        direct = {s.get('target'): s for s in data.get('directWindowShots', [])}
        check([{k: v.get('pixels', {}) for k, v in direct.items()}], mode, 'direct-window')
        for name in ('control',) + TARGETS:
            if not direct.get(name, {}).get('listed') or 'error' in direct.get(name, {}):
                issues.append(f'{mode}/direct-window/{name}: missing window or capture error')
    return {'verdict': 'LEAK' if leaks else 'INCONCLUSIVE' if issues else 'PASS_SAMPLED_PATHS',
            'sampleGroups': samples, 'leaks': leaks, 'issues': issues,
            'scope': 'Synthetic steady-state/selected filter transitions only. No universal guarantee; Mission Control excluded.'}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit('Usage: validate-matrix.py VISIBLE.json HIDDEN.json')
    result = validate(*(json.loads(Path(p).read_text()) for p in sys.argv[1:]))
    print(json.dumps(result, indent=2))
    sys.exit(1 if result['leaks'] else 2 if result['issues'] else 0)
