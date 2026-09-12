from pathlib import Path
import subprocess,tempfile
source=Path('tools/install-local.sh').read_text()
block=source[source.index('# Prepare and verify'):]
for failure,keep_backup in [(failure,keep) for keep in [False,True]
                            for failure in ['none','copy','staged-signature','installed-signature']]:
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
shift 2
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
        args=['bash',str(script),str(root),failure]+(['--keep-backup'] if keep_backup else [])
        result=subprocess.run(args,capture_output=True,text=True,errors="replace")
        expected='new' if failure=='none' else 'previous'
        assert (app/'marker').read_text()==expected,(failure,result.stdout,result.stderr)
        assert (result.returncode==0)==(failure=='none'),(failure,result.returncode,result.stdout,result.stderr)
        if failure=='none':
            backups=list(root.glob('wisp-install-backup.*/previous-Wisp.app/marker'))
            assert bool(backups)==keep_backup,(keep_backup,backups)
            assert all(p.read_text()=='previous' for p in backups)
            assert not list((root/'Applications').glob('.Wisp-install.*'))
        print(f'{failure}, keep_backup={keep_backup}: PASS (installed={expected}, exit={result.returncode})')
