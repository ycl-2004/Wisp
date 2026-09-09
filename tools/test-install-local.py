from pathlib import Path
import subprocess,tempfile
source=Path('tools/install-local.sh').read_text()
block=source[source.index('# Prepare and verify'):]
for failure in ['none','copy','staged-signature','installed-signature']:
    with tempfile.TemporaryDirectory(prefix='wisp-installer-test-') as tmp:
        root=Path(tmp)
        app=root/'Applications'/'Wisp.app'; app.mkdir(parents=True)
        (app/'marker').write_text('previous')
        built=root/'Built.app';built.mkdir();(built/'marker').write_text('new')
        script=root/'fixture.sh'
        script.write_text('''#!/bin/bash
set -euo pipefail
APP="$1/Applications/Wisp.app"
BUILT="$1/Built.app"
TMPDIR="$1"
failure="$2"
sign_calls=0
ditto() {
    [[ "$failure" != copy ]] || return 17
    cp -R "$2" "$3"
}
codesign() {
    sign_calls=$((sign_calls + 1))
    if [[ "$failure" == staged-signature && "$sign_calls" == 1 ]]; then return 18; fi
    if [[ "$failure" == installed-signature && "$sign_calls" == 2 ]]; then return 19; fi
    return 0
}
'''+block)
        result=subprocess.run(['bash',str(script),str(root),failure],capture_output=True,text=True,errors="replace")
        expected='new' if failure=='none' else 'previous'
        assert (app/'marker').read_text()==expected,(failure,result.stdout,result.stderr)
        assert (result.returncode==0)==(failure=='none'),(failure,result.returncode,result.stdout,result.stderr)
        if failure=='none':
            assert any(p.read_text()=='previous' for p in root.glob('wisp-install-backup.*/previous-Wisp.app/marker'))
        print(f'{failure}: PASS (installed={expected}, exit={result.returncode})')
