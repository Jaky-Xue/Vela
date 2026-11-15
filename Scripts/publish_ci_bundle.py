"""Mirror this run's evidence onto a separate generated branch when API access is unavailable.
No source branch is changed. Credentials stay in runner-local Git configuration.
"""
import hashlib,json,os,plistlib,re,shutil,subprocess,sys,tempfile
from pathlib import Path

kind=sys.argv[1]
root=Path.cwd()
sha=os.environ['GITHUB_SHA']; run=os.environ['GITHUB_RUN_ID']; attempt=os.environ['GITHUB_RUN_ATTEMPT']
record={'commit':sha,'run':run,'kind':kind,'workflow':'https://github.com/'+os.environ['GITHUB_REPOSITORY']+'/actions/runs/'+run}
folder=Path(tempfile.mkdtemp(prefix='vela-ci-bundle-'))
if kind.startswith('tests'):
    log=Path('test-output.log').read_text(encoding='utf-8',errors='replace') if Path('test-output.log').exists() else ''
    results=re.findall(r"Test Case '([^']+)' (passed|failed|skipped)",log)
    final=dict(results)
    counts=re.findall(r'Executed (\d+) tests?, with (\d+) failures?',log)
    record.update(tests=len(final),testExecutions=len(results),retriedTests=sorted({n for n,r in results if r=='failed'}),
                  failedAttempts=sum(r=='failed' for _,r in results),
                  finalFailures=[n for n,r in final.items() if r=='failed'],
                  testGate='success' if '** TEST SUCCEEDED **' in log and final and all(r=='passed' for r in final.values()) else 'failure')
    if Path('TestResults.xcresult').exists():
        proc=subprocess.run(['xcrun','xcresulttool','get','test-results','summary','--path','TestResults.xcresult'],capture_output=True,text=True)
        if proc.returncode == 0:
            summary=json.loads(proc.stdout)
            (folder/'xcresult-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2),encoding='utf-8')
            record['observedConsoleTests']=record['tests']
            record['xcresultSummary']=summary
            if isinstance(summary.get('totalTestCount'),int): record['tests']=summary['totalTestCount']
            if summary.get('failedTests',0) > 0: record['testGate']='failure'
    if counts: record['testExecutions']=max(int(n) for n,_ in counts)
    errors=[l for l in log.splitlines() if ('error:' in l and 'ProcessAssertion' not in l and 'error: (null)' not in l) or " failed (" in l or 'Executed ' in l or '** TEST' in l]
    (folder/'test-summary.txt').write_text('\n'.join(errors),encoding='utf-8')
    if Path('ui-previews').exists(): shutil.copytree('ui-previews',folder/'ui-previews')
else:
    ipa=Path('Vela-unsigned.ipa'); shutil.copy2(ipa,folder/ipa.name)
    info=plistlib.loads(Path('build/Build/Products/Release-iphoneos/Vela.app/Info.plist').read_bytes())
    record.update(version=info['CFBundleShortVersionString'],build=info['CFBundleVersion'],sha256=hashlib.sha256(ipa.read_bytes()).hexdigest(),bytes=ipa.stat().st_size,signing='unsigned')
(folder/'metadata.json').write_text(json.dumps(record,ensure_ascii=False,indent=2),encoding='utf-8')
branch='ci-bundles/'+sha[:12]+'-'+run+'-'+attempt+'-'+kind
header=subprocess.check_output(['git','config','--get','http.https://github.com/.extraheader'],text=True).strip()
remote=subprocess.check_output(['git','remote','get-url','origin'],text=True).strip()
def git(*args):
    proc=subprocess.run(['git','-C',str(folder),*args],capture_output=True)
    if proc.returncode: raise RuntimeError('Could not publish generated CI bundle')
git('init'); git('config','user.name','Vela CI'); git('config','user.email','41898282+github-actions[bot]@users.noreply.github.com')
# Do not print the header or include it in a shell command.
git('config','http.https://github.com/.extraheader',header)
git('add','.'); git('commit','-m','Generated CI evidence for '+sha)
git('remote','add','origin',remote); git('push','origin','HEAD:refs/heads/'+branch)
print('CI evidence branch: '+branch)
