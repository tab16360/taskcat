"""Exercise the actual Swift app command boundary; no model/network/Reminders side effects."""
import copy,json,subprocess,uuid
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]
TASK='00000000-0000-4000-8000-000000000001'
ID='00000000-0000-4000-8000-000000000002'

@pytest.fixture(scope='session')
def domain_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('domain-contract')
    source=folder/'DomainTestMain.swift'
    source.write_text('''import Foundation
@main struct ContractProbe {
 static func main() {
  do {
   let args=CommandLine.arguments
   if args[1]=="profile-origin" {
    var p=ModelPreferences();p.migrateProfiles();let before=p.keyService;p.cloudURL="https://different.example/v1"
    print(before==p.keyService ? "unsafe" : "isolated");return
   }
   if args[1]=="key-service" {
    var p=ModelPreferences();p.cloudURL=args[2]
    print(p.keyService);return
   }
   if args[1]=="url" {
    var p=ModelPreferences();p.cloudURL=args[2]
    print(try p.endpoint().absoluteString);return
   }
   let task=ManagedTask(id:"00000000-0000-4000-8000-000000000001",title:"打印模板",notes:"",group:.work,status:"doing",progress:20,dueAt:nil,completed:false,softDeleted:false,archived:false,conflicted:false)
   let c=try TaskCommand.decode(Data(contentsOf:URL(fileURLWithPath:args[1])),expectedId:"00000000-0000-4000-8000-000000000002",tasks:[task])
   let encoded=try JSONEncoder().encode(c)
   _=try TaskCommand.decode(encoded,expectedId:c.operationId,tasks:[task])
   print(String(data:encoded,encoding:.utf8)!)
  } catch { fputs("rejected\\n",stderr);exit(2) }
 }
}
''')
    executable=folder/'contract'
    r=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'poc/metadata-journal/OperationJournal.swift'),str(ROOT/'apps/macos/Sources/Domain.swift'),str(source),'-o',str(executable)],capture_output=True,text=True,timeout=90)
    assert r.returncode==0,r.stderr
    return executable

def command(**kw):
    value=dict(operationId=ID,intent='update_task',taskId=TASK,patch={'progress':50,'status':'doing'},dateText=None,requiresConfirmation=False)
    value.update(kw);return value

def run(cli,tmp_path,value,expected=0):
    p=tmp_path/'command.json';p.write_text(json.dumps(value))
    r=subprocess.run([str(cli),str(p)],capture_output=True,text=True,timeout=10)
    assert r.returncode==expected,r.stderr
    return json.loads(r.stdout) if r.stdout else None

def test_progress_update_and_null_are_valid(domain_cli,tmp_path):
    assert run(domain_cli,tmp_path,command())['requiresConfirmation'] is False
    assert run(domain_cli,tmp_path,command(patch={'progress':None}))['patch']['progress'] is None

@pytest.mark.parametrize('c',[
 command(operationId=str(uuid.uuid4())),command(taskId=str(uuid.uuid4())),command(taskId=None),
 command(patch={'progress':True}),command(patch={'progress':101}),command(patch={'shell':'unsafe'}),
 command(intent='delete_task',patch={'title':'unrequested rename'}),
 command(intent='complete_task',patch={'status':'todo'}),
 command(intent='reopen_task',patch={'status':'done'}),
 command(intent='create_task',taskId=None,patch={'title':'打印模板'}),
 command(intent='create_task',taskId=None,patch={}),
 command(intent='move_task',patch={}),
 command(intent='query_tasks',patch={'progress':100}),
 command(extra='unexpected')])
def test_bad_or_unrelated_changes_do_not_cross_boundary(domain_cli,tmp_path,c):
    run(domain_cli,tmp_path,c,expected=2)

@pytest.mark.parametrize('changes',[
 {'intent':'delete_task','patch':{}},{'intent':'complete_task','patch':{}},
 {'intent':'reopen_task','patch':{}},{'patch':{'status':'done'}},
 {'patch':{'title':'新的打印模板'}},{'dateText':'下周五'}])
def test_task_changes_follow_the_model_uncertainty_flag(domain_cli,tmp_path,changes):
    # Whether to ask is decided later from the message itself (ConversationRules.needsConfirmation).
    assert run(domain_cli,tmp_path,command(**changes))['requiresConfirmation'] is False
    assert run(domain_cli,tmp_path,command(**changes,requiresConfirmation=True))['requiresConfirmation'] is True

@pytest.mark.parametrize('url,valid,endpoint',[
 ('https://example.test/v1',True,'https://example.test/v1/chat/completions'),
 ('https://example.test/',True,'https://example.test/chat/completions'),
 ('http://127.0.0.1:11434/v1',True,'http://127.0.0.1:11434/v1/chat/completions'),
 ('http://example.test/v1',False,None),('https://user:key@example.test/v1',False,None),
 ('https://example.test/v1?key=secret',False,None)])
def test_endpoint_validation(domain_cli,url,valid,endpoint):
    r=subprocess.run([str(domain_cli),'url',url],capture_output=True,text=True,timeout=10)
    assert r.returncode==(0 if valid else 2)
    if valid:assert r.stdout.strip()==endpoint


def test_keys_are_bound_to_origin_not_arbitrary_provider_url(domain_cli):
    def service(url):return subprocess.check_output([str(domain_cli),'key-service',url],text=True).strip()
    assert service('https://a.example/v1')!=service('https://b.example/v1')
    assert service('https://a.example/v1')==service('https://a.example:443/other')
    assert service('http://127.0.0.1:11434/v1')!=service('http://127.0.0.1:1234/v1')


def test_internal_manual_create_retains_explicit_null_contract_fields(domain_cli,tmp_path):
    result=run(domain_cli,tmp_path,command(intent='create_task',taskId=None,patch={'title':'合成手动任务'}))
    assert 'taskId' in result and result['taskId'] is None
    assert 'dateText' in result and result['dateText'] is None


@pytest.mark.parametrize('intent,patch',[
 ('create_group',{'groupId':'项目A'}),('query_groups',{}),
 ('create_task',{'title':'合成项目事项','groupId':'项目A'}),
 ('create_task',{'title':'合成阶段事项','notes':'开发完成，待测试','status':'waiting'})])
def test_dynamic_groups_and_stage_notes(domain_cli,tmp_path,intent,patch):
    result=run(domain_cli,tmp_path,command(intent=intent,taskId=None,patch=patch))
    assert result['intent']==intent


@pytest.mark.parametrize('intent,patch',[
 ('create_group',{}),('create_group',{'groupId':'bad/name'}),
 ('query_groups',{'status':'todo'}),('create_task',{'title':'合成','notes':'x'*4001})])
def test_invalid_group_and_note_commands_are_rejected(domain_cli,tmp_path,intent,patch):
    run(domain_cli,tmp_path,command(intent=intent,taskId=None,patch=patch),expected=2)


def test_group_alias_normalizes_before_query_and_write(domain_cli,tmp_path):
    result=run(domain_cli,tmp_path,command(intent='query_tasks',taskId=None,patch={'groupId':'收件箱'}))
    assert result['patch']['groupId']=='inbox'


@pytest.mark.parametrize('top',['周日晚上8:00',None])
def test_local_model_nested_date_canonicalizes(domain_cli,tmp_path,top):
    result=run(domain_cli,tmp_path,command(patch={'dateText':'周日晚上8:00'},dateText=top))
    assert result['dateText']=='周日晚上8:00' and result['patch']=={}


@pytest.mark.parametrize('patch,top',[
 ({'dateText':'周日晚上8:00'},'周六晚上8:00'),
 ({'dateText':123},None),({'dateText':''},None),
 ({'dateText':'周日晚上8:00','shell':'unsafe'},None),
 ({'dueAt':'2026-10-25T20:00:00+08:00'},None)])
def test_conflicting_dates_and_other_unknown_fields_remain_rejected(domain_cli,tmp_path,patch,top):
    run(domain_cli,tmp_path,command(patch=patch,dateText=top),expected=2)


@pytest.mark.parametrize('intent,patch',[
 ('rename_group',{'groupId':'wenshu','newGroupId':'mircrosung'}),
 ('delete_group',{'groupId':'wenshu'})])
def test_group_mutations_always_confirm(domain_cli,tmp_path,intent,patch):
    c=run(domain_cli,tmp_path,command(intent=intent,taskId=None,patch=patch))
    assert c['requiresConfirmation'] and c['taskId'] is None

@pytest.mark.parametrize('intent,patch',[
 ('rename_group',{'groupId':'inbox','newGroupId':'other'}),
 ('delete_group',{'groupId':'收件箱'}),
 ('rename_group',{'groupId':'x','newGroupId':'x'}),
 ('rename_group',{'groupId':'x'}),
 ('update_task',{'newGroupId':'wrong-field'}),
 ('purge_task',{})])
def test_inbox_and_permanent_deletion_cannot_be_bypassed_by_model(domain_cli,tmp_path,intent,patch):
    run(domain_cli,tmp_path,command(intent=intent,taskId=None if 'group' in intent else TASK,patch=patch),expected=2)

@pytest.mark.parametrize('progress,result',[(1,10),(24,20),(35,40),(87,90),(94,90),(95,100),(100,100)])
def test_progress_uses_ten_point_steps_and_full_progress_completes(domain_cli,tmp_path,progress,result):
    c=run(domain_cli,tmp_path,command(patch={'progress':progress}))
    assert c['patch']['progress']==result
    if result==100:assert c['patch']['status']=='done' and not c['requiresConfirmation']


def test_unsaved_profile_origin_changes_cannot_reuse_old_credentials(domain_cli):
    assert subprocess.check_output([str(domain_cli),'profile-origin'],text=True).strip()=='isolated'
