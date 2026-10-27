"""Run the production file credential store in isolated directories; synthetic keys only."""
import json, os, subprocess
from pathlib import Path
import pytest

ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture(scope='session')
def secrets_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('local-secrets-cli')
    source=folder/'Probe.swift'
    source.write_text('''import Foundation
enum AppFailure:Error {case message(String)}
@main struct Probe {
 static func main() {
  do {
   let a=CommandLine.arguments
   let store=LocalSecrets(directory:URL(fileURLWithPath:a[1]))
   if a[2]=="save" {try store.save(a[5],service:a[3],account:a[4]);print("saved")}
   else {print(try store.read(service:a[3],account:a[4]) ?? "missing")}
  } catch {print("rejected");exit(2)}
 }
}
''')
    binary=folder/'probe'
    r=subprocess.run(['swiftc','-parse-as-library',str(ROOT/'apps/macos/Sources/LocalSecrets.swift'),str(source),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert r.returncode==0,r.stderr
    return binary

def invoke(binary,folder,*args):
    return subprocess.run([str(binary),str(folder),*args],capture_output=True,text=True,timeout=10)

def test_survives_new_process_and_private_modes(secrets_cli,tmp_path):
    folder=tmp_path/'credentials'
    assert invoke(secrets_cli,folder,'save','cloud','app','synthetic-cloud').returncode==0
    assert invoke(secrets_cli,folder,'read','cloud','app').stdout.strip()=='synthetic-cloud'
    assert folder.stat().st_mode & 0o777==0o700
    files=list(folder.iterdir())
    assert len(files)==1 and files[0].stat().st_mode & 0o777==0o600

def test_services_accounts_and_origins_are_isolated(secrets_cli,tmp_path):
    folder=tmp_path/'credentials'
    for service,account,value in [('profile-a','app','a'),('profile-b','app','b'),('profile-a','poc','legacy')]:
        assert invoke(secrets_cli,folder,'save',service,account,value).returncode==0
    for service,account,value in [('profile-a','app','a'),('profile-b','app','b'),('profile-a','poc','legacy')]:
        assert invoke(secrets_cli,folder,'read',service,account).stdout.strip()==value
    assert invoke(secrets_cli,folder,'read','different-origin','app').stdout.strip()=='missing'

def test_overwrite_leaves_one_valid_file(secrets_cli,tmp_path):
    folder=tmp_path/'credentials'
    for value in ['before','after']:
        assert invoke(secrets_cli,folder,'save','cloud','app',value).returncode==0
    assert invoke(secrets_cli,folder,'read','cloud','app').stdout.strip()=='after'
    assert len(list(folder.iterdir()))==1
    assert json.loads(next(folder.iterdir()).read_text())=='after'

def test_reject_symlink_directory(secrets_cli,tmp_path):
    real=tmp_path/'real';real.mkdir()
    link=tmp_path/'link';link.symlink_to(real,target_is_directory=True)
    assert invoke(secrets_cli,link,'save','cloud','app','test').returncode==2
    assert not list(real.iterdir())

def test_reject_symlink_file(secrets_cli,tmp_path):
    folder=tmp_path/'credentials'
    assert invoke(secrets_cli,folder,'save','cloud','app','test').returncode==0
    item=next(folder.iterdir());item.unlink()
    victim=tmp_path/'victim';victim.write_text('unchanged');item.symlink_to(victim)
    assert invoke(secrets_cli,folder,'read','cloud','app').returncode==2
    assert invoke(secrets_cli,folder,'save','cloud','app','test').returncode==2
    assert victim.read_text()=='unchanged'

def test_service_name_cannot_escape_directory(secrets_cli,tmp_path):
    folder=tmp_path/'credentials'
    assert invoke(secrets_cli,folder,'save','../../escape','app','test').returncode==0
    assert not (tmp_path/'escape').exists()
    assert invoke(secrets_cli,folder,'read','../../escape','app').stdout.strip()=='test'
