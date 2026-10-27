"""Update rules and the swap script, with synthetic releases and throwaway bundles; no network."""
import json,os,subprocess
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]
SCRIPT=ROOT/'apps/macos/Resources/update-install.sh'
REPO='https://github.com/tab16360/taskcat/releases/download'

@pytest.fixture(scope='session')
def update_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('update-rules')
    main=folder/'UpdateMain.swift'
    main.write_text(r'''import Foundation
@main struct UpdateProbe {
 static func main() throws {
  let a=CommandLine.arguments
  switch a[1] {
  case "compare":
   guard let x=AppVersion(a[2]),let y=AppVersion(a[3]) else{print("invalid");return}
   print(x<y ? "<" : x>y ? ">" : "=")
  case "pick":
   let releases=try JSONDecoder().decode([ReleaseFeedItem].self,from:Data(a[3].utf8))
   print(UpdateRules.pick(releases,current:AppVersion(a[2])!,arch:"arm64").map{$0.tag} ?? "none")
  case "checksum":print(UpdateRules.checksum(a[2],archiveName:"TaskCat-arm64.zip") ?? "nil")
  case "due":
   let now=Date(timeIntervalSince1970:1_000_000)
   print(UpdateRules.checkDue(lastCheck:a[2]=="never" ? nil : now.addingTimeInterval(Double(a[2])!),now:now) ? "due" : "wait")
  default:fatalError()
  }
 }
}
''')
    binary=folder/'updates'
    result=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'apps/macos/Sources/UpdateRules.swift'),str(main),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert result.returncode==0,result.stderr
    return binary

def run(cli,*args):return subprocess.check_output([str(cli),*args],text=True,timeout=10).strip()

@pytest.mark.parametrize('a,b,expected',[
 ('0.2.5','v0.2.6','<'),('0.2.5','0.2.5','='),('0.2.10','0.2.9','>'),('0.3','0.3.0','='),
 ('0.3.0-preview.1','0.3.0','<'),('0.3.0-preview.2','0.3.0-preview.10','<'),('v0.2.1-preview.1','0.2.5','<'),
 ('1.0.0','0.9.9','>'),('abc','0.1','invalid'),('1..2','0.1','invalid')])
def test_version_order(update_cli,a,b,expected):assert run(update_cli,'compare',a,b)==expected

def release(tag,draft=False,assets=('TaskCat-arm64.zip','TaskCat-arm64.zip.sha256'),base=None):
    return {'tag_name':tag,'draft':draft,'prerelease':True,'body':'notes','html_url':'https://github.com/tab16360/taskcat/releases/tag/'+tag,
            'assets':[{'name':n,'browser_download_url':f'{base or REPO}/{tag}/{n}','size':1} for n in assets]}

@pytest.mark.parametrize('current,releases,expected',[
 ('0.2.5',[release('v0.2.1-preview.1'),release('v0.2.0-preview.1')],'none'),
 ('0.2.5',[release('v0.2.6'),release('v0.3.0-preview.1'),release('v0.2.7')],'v0.3.0-preview.1'),
 ('0.2.5',[release('v0.4.0',draft=True),release('v0.2.6')],'v0.2.6'),
 ('0.2.5',[release('v0.4.0',assets=('TaskCat-arm64.zip',)),release('v0.2.6')],'v0.2.6'),
 ('0.2.5',[release('v0.4.0',assets=('TaskCat-x86_64.zip','TaskCat-x86_64.zip.sha256'))],'none'),
 ('0.2.5',[release('v0.4.0',base='https://example.com/tab16360/taskcat/releases/download')],'none'),
 ('0.2.5',[release('v0.4.0',base='https://github.com/someone/fork/releases/download')],'none'),
 ('0.2.5',[release('nightly'),release('v0.2.6')],'v0.2.6')])
def test_pick_only_newer_complete_releases_from_this_repository(update_cli,current,releases,expected):
    assert run(update_cli,'pick',current,json.dumps(releases))==expected

H='d37ad1bb03836fa8db54dd4404525b5b9248b5a639dbcb67494567b73250c050'
@pytest.mark.parametrize('text,expected',[
 (f'{H}  TaskCat-arm64.zip\n',H),(f'{H.upper()} *TaskCat-arm64.zip',H),
 (f'{H}  TaskCat-x86_64.zip','nil'),(f'{H[:-1]}  TaskCat-arm64.zip','nil'),('not a checksum','nil')])
def test_checksum_must_name_the_archive(update_cli,text,expected):assert run(update_cli,'checksum',text)==expected

@pytest.mark.parametrize('offset,expected',[('never','due'),('-3600','wait'),('-86400','due'),('7200','due')])
def test_daily_check_interval(update_cli,offset,expected):assert run(update_cli,'due',offset)==expected

def bundle(path,marker):
    (path/'Contents').mkdir(parents=True);(path/'Contents/marker').write_text(marker);return path

def exited_pid():
    p=subprocess.Popen(['/usr/bin/true']);p.wait();return str(p.pid)

def swap(tmp_path,staged):
    target=bundle(tmp_path/'Apps/记事喵.app','old');backup=tmp_path/'support/previous-build.app'
    result=subprocess.run(['/bin/bash',str(SCRIPT),exited_pid(),str(target),str(staged),str(backup)],capture_output=True,text=True,timeout=30,env={**os.environ,'TASKCAT_UPDATE_NO_OPEN':'1'})
    return result,target,backup

def test_swap_installs_staged_build_and_keeps_previous(tmp_path):
    staged=bundle(tmp_path/'Apps/.TaskCat-update-x.app','new')
    result,target,backup=swap(tmp_path,staged)
    assert result.returncode==0,result.stdout+result.stderr
    assert (target/'Contents/marker').read_text()=='new' and (backup/'Contents/marker').read_text()=='old' and not staged.exists()

def test_failed_swap_restores_previous_build(tmp_path):
    result,target,backup=swap(tmp_path,tmp_path/'Apps/.TaskCat-update-missing.app')
    assert result.returncode==1 and 'restoring' in result.stdout
    assert (target/'Contents/marker').read_text()=='old' and not backup.exists()
