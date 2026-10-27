"""Periodic sync must not rewrite unchanged files: each rewrite is an fsynced atomic replace."""
import json,os,stat,subprocess,uuid
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture(scope='session')
def write_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('persistence-writes')
    persistence=folder/'Persistence.swift'
    persistence.write_text((ROOT/'apps/macos/Sources/Infrastructure.swift').read_text().split('struct SecretStore')[0])
    main=folder/'Main.swift'
    main.write_text(r'''import Foundation
@main struct Probe {
 static func main() throws {
  let url=URL(fileURLWithPath:CommandLine.arguments[1])
  try AppPaths.write(["value":CommandLine.arguments[2]],to:url)
 }
}
''')
    sources=["Domain","ConversationLogic","TaskBoard","NotificationRules","TaskSnapshots","TaskBackup"]
    binary=folder/'probe'
    result=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'poc/metadata-journal/OperationJournal.swift'),str(persistence),
        *[str(ROOT/f'apps/macos/Sources/{n}.swift') for n in sources],str(main),'-o',str(binary)],capture_output=True,text=True,timeout=120)
    assert result.returncode==0,result.stderr
    return binary

@pytest.fixture(scope='session')
def journal_cli(tmp_path_factory):
    binary=tmp_path_factory.mktemp('journal-writes')/'MetadataProbe'
    result=subprocess.run(['swiftc','-swift-version','5','-parse-as-library',str(ROOT/'poc/metadata-journal/OperationJournal.swift'),
        str(ROOT/'poc/metadata-journal/MetadataProbe.swift'),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert result.returncode==0,result.stderr
    return binary

def test_unchanged_save_keeps_the_file_and_changed_save_replaces_it(write_cli,tmp_path):
    target=tmp_path/'state.json'
    subprocess.run([str(write_cli),str(target),'a'],check=True)
    first=target.stat()
    subprocess.run([str(write_cli),str(target),'a'],check=True)
    assert target.stat().st_ino==first.st_ino and target.stat().st_mtime_ns==first.st_mtime_ns
    subprocess.run([str(write_cli),str(target),'b'],check=True)
    assert target.stat().st_ino!=first.st_ino and json.loads(target.read_text())=={'value':'b'}
    assert stat.S_IMODE(target.stat().st_mode)==0o600

def test_reimporting_a_published_operation_writes_nothing(journal_cli,tmp_path):
    journal=tmp_path/'journal';journal.mkdir()
    op=dict(schemaVersion=1,operationId=str(uuid.uuid4()),entityType='task',entityId='00000000-0000-4000-8000-000000000001',
        actorId='00000000-0000-4000-8000-000000000003',parents=[],createdAt='2026-10-27T00:00:00Z',source='poc',summary='synthetic',patch={'status':'doing'})
    incoming=tmp_path/'op.json';incoming.write_text(json.dumps(op))
    run=lambda:subprocess.run([str(journal_cli),'import',str(journal),str(incoming)],capture_output=True,text=True,timeout=15)
    assert json.loads(run().stdout)['added'] is True
    # A read-only directory makes any staging write fail, so success proves nothing was written.
    os.chmod(journal,0o500)
    try:
        again=run()
        assert again.returncode==0,again.stderr
        assert json.loads(again.stdout)['added'] is False
    finally:os.chmod(journal,0o700)
