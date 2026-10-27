"""Run the real Swift rules with a fixed UTC+8 clock; no model or personal reminders."""
import json,subprocess,os
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture(scope='session')
def rules_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('conversation-rules')
    main=folder/'RulesMain.swift'
    main.write_text(r'''import Foundation
@main struct RulesProbe {
 static func main() throws {
  let a=CommandLine.arguments
  let f=ISO8601DateFormatter()
  let now=f.date(from:"2026-10-23T06:00:00Z")!
  func task(_ id:String,_ status:String,_ completed:Bool=false,_ deleted:Bool=false,_ archived:Bool=false)->ManagedTask {
   ManagedTask(id:id,title:"合成_任务_"+id,notes:"",group:.inbox,status:status,progress:nil,dueAt:nil,completed:completed,softDeleted:deleted,archived:archived,conflicted:false)
  }
  let tasks=[task("a","todo"),task("b","doing"),task("c","waiting"),task("d","done",true),task("e","cancelled"),task("f","todo",false,true),task("g","todo",false,false,true)]
  switch a[1] {
  case "page":
   print(TaskBoard.page(Array(0..<Int(a[2])!),expanded:a[3]=="expanded").map(String.init).joined(separator:","))
  case "board":
   let lens=TaskLens(rawValue:a[2])!
   print(TaskBoard.select(tasks,group:a.count>3 ? a[3] : "all",lens:lens,trash:a.contains("trash"),includeCompleted:a.contains("all-statuses")).map(\.id).joined(separator:","))
  case "model-control":
   var p=ModelPreferences();p.cloudModel="qwen3.8-flash";p.migrateProfiles()
   switch ModelConversation.request(a[2]) {
   case .help:print("help")
   case .query:print("query")
   case .select(let name):
    do{print("select:"+(try ModelConversation.resolve(name,profiles:p.profiles!)).provider)}catch{print("unmatched")}
   case nil:print("nil")
   }
  case "creation-prefix":
   let c=TaskCommand(operationId:"op",intent:a.count>4 ? a[4] : "create_task",taskId:nil,patch:["title":.text(a[3]),"groupId":.text("inbox")],dateText:nil,requiresConfirmation:false)
   let cleaned=try ConversationRules.cleanCreation(c,input:a[2],groups:[.inbox,TaskGroup(rawValue:"genetron")!])
   print(try String(data:JSONSerialization.data(withJSONObject:["title":cleaned.text("title")!,"groupId":cleaned.text("groupId")!]),encoding:.utf8)!)
  case "bark":
   var t=task("poc","todo");t.dueAt=now.addingTimeInterval(Double(a[2])!)
   if a[3]=="done" {t.completed=true};if a[3]=="deleted"{t.softDeleted=true};if a[3]=="conflicted"{t.conflicted=true};if a[3]=="cancelled"{t.status="cancelled"}
   print(BarkSchedule.isDue(t,enabledAt:now.addingTimeInterval(-60),now:now) ? "due" : "skip")
  case "scope":
   let c=TaskCommand(operationId:"op",intent:"query_tasks",taskId:nil,patch:[:],dateText:nil,requiresConfirmation:false)
   let scoped=try ConversationRules.scopeQuery(c,input:a[2],groups:[.inbox,TaskGroup(rawValue:"POC交互验证")!]);print(scoped.text("groupId") ?? "nil")
  case "feedback":
   let v=FeedbackSections(a[2]);print(try String(data:JSONSerialization.data(withJSONObject:["content":v.content,"hint":v.hint as Any? ?? NSNull()]),encoding:.utf8)!)
  case "group-command":
   let c=try GroupConversation.command(a[2],id:"op",groups:[.inbox,TaskGroup(rawValue:"wenshu")!,TaskGroup(rawValue:"项目A")!])
   if let c {print(String(data:try JSONEncoder().encode(c),encoding:.utf8)!)}else{print("nil")}
  case "profiles":
   var p=ModelPreferences();p.cloudURL="https://configured.example/v1";p.cloudModel="existing-cloud";p.localModel="existing-local";p.provider="local";p.migrateProfiles()
   let decoded=try JSONDecoder().decode(ModelPreferences.self,from:JSONEncoder().encode(p));p.activateProfile("legacy-cloud")
   print(try String(data:JSONSerialization.data(withJSONObject:["count":p.profiles!.count,"cloud":p.model,"local":decoded.model,"selected":decoded.selectedProfileID!]),encoding:.utf8)!)
  case "due":
   let due=now.addingTimeInterval(Double(a[2])!*3600)
   print(TaskBoard.bucket(due,now:now).rawValue+"|"+TaskBoard.dueLabel(due,now:now))
  case "timeline":
   var items=[task("x","todo"),task("y","todo"),task("z","todo"),task("w","todo")]
   items[0].dueAt=now.addingTimeInterval(-90000);items[1].dueAt=now.addingTimeInterval(3600);items[2].dueAt=now.addingTimeInterval(9*86400)
   print(TaskBoard.timeline(items,now:now).map{$0.bucket.rawValue+":"+$0.tasks.map(\.id).joined()}.joined(separator:","))
  case "date": print(DateSuggestion.date(for:a[2],now:now).map{f.string(from:$0)} ?? "nil")
  case "extract":print(DateSuggestion.explicitDateText(in:a[2]) ?? "nil")
  case "query":
   let command=TaskCommand(operationId:"op",intent:"query_tasks",taskId:nil,patch:a.count>3 ? ["status":.text(a[3])] : [:],dateText:nil,requiresConfirmation:false)
   let selected=ConversationRules.query(tasks,input:a[2],command:command)
   print(selected.map(\.id).joined(separator:","))
  case "numbers":
   var n=TaskNumbers();n.assign(Array(tasks.prefix(3)));let old=n.values
   n.assign([tasks[2],tasks[0],tasks[3]])
   print(old==n.values.filter{$0.key != "d"} && n.task(2,in:tasks)?.id=="b" && n.values["d"]==4 ? "stable" : "broken")
  case "list":
   var n=TaskNumbers();n.assign(tasks)
   print(ConversationRules.list(Array(tasks.prefix(3)),numbers:n))
  case "confirmation":
   if let c=ConversationRules.confirmation(a[2]) {print((c.cancel ? "cancel:" : "confirm:")+c.code)} else {print("nil")}
  case "matches":
   var r=RequestRecord(id:"38db02e1-0000-4000-8000-000000000001",source:"wechat:A",text:"合成",createdAt:"");r.phase=a[4];r.confirmationNumber=a[5]=="legacy" ? nil : 1
   print(ConversationRules.matchesConfirmation(r,source:a[2],code:a[3]) ? "yes" : "no")
  case "refine":
   let c=TaskCommand(operationId:"op",intent:"complete_task",taskId:"a",patch:["status":.text("done")],dateText:nil,requiresConfirmation:false)
   let refined=ConversationRules.refine(c,input:a[2]);print(refined.intent+":"+(refined.text("status") ?? "")+":"+(refined.dateText ?? "nil"))
  case "group":print(TaskGroup(rawValue:a[2]).map{$0.rawValue+"|"+$0.calendarTitle+"|"+$0.uuid} ?? "nil")
  case "defaults":print(TaskGroup.allCases.map(\.calendarTitle).joined(separator:","))
  default: fatalError()
  }
 }
}
''')
    binary=folder/'rules'
    result=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'poc/metadata-journal/OperationJournal.swift'),str(ROOT/'apps/macos/Sources/Domain.swift'),str(ROOT/'apps/macos/Sources/TaskBoard.swift'),str(ROOT/'apps/macos/Sources/ConversationLogic.swift'),str(ROOT/'apps/macos/Sources/NotificationRules.swift'),str(main),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert result.returncode==0,result.stderr
    return binary

def run(cli,*args):
    return subprocess.check_output([str(cli),*args],text=True,timeout=10,env={**os.environ,'TZ':'Asia/Singapore'}).strip()

@pytest.mark.parametrize('text,expected',[
 ('10.25','2026-10-25T01:00:00Z'),('10月25日','2026-10-25T01:00:00Z'),
 ('2026-10-25','2026-10-25T01:00:00Z'),('明天下午三点','2026-10-24T07:00:00Z'),
 ('10.25下午三点半','2026-10-25T07:30:00Z'),('10.25 15:40','2026-10-25T07:40:00Z'),
 ('下周五','2026-10-30T01:00:00Z'),('12.31','2026-12-31T01:00:00Z'),
 ('1.2','2027-01-02T01:00:00Z'),('2026-02-30','nil'),('13.25','nil'),('某天','nil'),('10.25 25:00','nil')])
def test_dates(rules_cli,text,expected):assert run(rules_cli,'date',text)==expected

# Fixed clock is 14:00 on Friday 2026-10-23 in UTC+8.
@pytest.mark.parametrize('hours,expected',[
 ('-1','overdue|已过 13:00'),('-26','overdue|逾期 1 天'),('3','today|今天 17:00'),
 ('19','tomorrow|明天 09:00'),('70','week|周一 12:00'),('300','later|11月5日')])
def test_due_buckets_and_labels(rules_cli,hours,expected):assert run(rules_cli,'due',hours)==expected

def test_timeline_keeps_bucket_order_and_skips_empty(rules_cli):
    assert run(rules_cli,'timeline')=='overdue:x,today:y,later:z,none:w'

@pytest.mark.parametrize('text,expected',[
 ('开发完成，待测试，10.25提交git','10.25'),('任务5明天下午三点提交','明天下午三点'),
 ('10.25下午三点半提交git','10.25下午三点半'),('普通事项','nil')])
def test_date_text_keeps_time(rules_cli,text,expected):assert run(rules_cli,'extract',text)==expected

@pytest.mark.parametrize('text,status,expected',[
 ('现在有几个待办',None,'a,b,c'),('查询未完成任务','todo','a,b,c'),
 ('列出已完成任务',None,'d'),('全部任务',None,'a,b,c,d,e'),('查看进行中任务','doing','b'),
 ('查看待测试任务','waiting','c')])
def test_pending_queries_exclude_completed_cancelled_deleted_archived(rules_cli,text,status,expected):
    assert run(rules_cli,'query',text,*([status] if status else []))==expected

def test_stable_numbers_survive_reordering_and_new_tasks(rules_cli):assert run(rules_cli,'numbers')=='stable'
def test_numbered_reply_has_blank_lines_and_retains_underscores(rules_cli):
    reply=run(rules_cli,'list');assert '1、合成_任务_a\n' in reply and '\n\n2、' in reply and '任务5标记完成' in reply

@pytest.mark.parametrize('text,expected',[('确认1','confirm:1'),('确认 12','confirm:12'),('取消2','cancel:2'),('确认38db02e1','confirm:38db02e1'),('确认 1 再删掉所有','nil')])
def test_short_confirmation_parser(rules_cli,text,expected):assert run(rules_cli,'confirmation',text)==expected

@pytest.mark.parametrize('source,code,phase,kind,expected',[
 ('wechat:A','1','awaiting_confirmation','new','yes'),('wechat:B','1','awaiting_confirmation','new','no'),
 ('wechat:A','1','applied','new','no'),('wechat:A','2','awaiting_confirmation','new','no'),
 ('wechat:A','38db02e1','awaiting_confirmation','legacy','yes'),('wechat:A','3','awaiting_confirmation','legacy','no')])
def test_confirmation_is_scoped_to_conversation(rules_cli,source,code,phase,kind,expected):assert run(rules_cli,'matches',source,code,phase,kind)==expected

def test_development_done_waiting_tests_is_not_task_completed(rules_cli):
    assert run(rules_cli,'refine','开发完成，待测试，10.25提交git')=='update_task:waiting:10.25'
def test_only_inbox_is_initialized(rules_cli):assert run(rules_cli,'defaults')=='AI任务秘书-收件箱'
def test_custom_group_stable_identity_and_invalid_names(rules_cli):
    one=run(rules_cli,'group','产品研发');assert one==run(rules_cli,'group','产品研发') and '|AI任务秘书-产品研发|' in one
    assert run(rules_cli,'group','收件箱').startswith('inbox|')
    assert run(rules_cli,'group','bad/name')=='nil' and run(rules_cli,'group','all')=='nil'


@pytest.mark.parametrize('text', ['周日晚上8:00','周日晚上八点','星期天晚上8：00','周日20:00'])
def test_sunday_evening_is_20_not_08(rules_cli,text):
    assert run(rules_cli,'date',text)=='2026-10-25T12:00:00Z'
    assert run(rules_cli,'extract','太工这个任务改成'+text)==text


@pytest.mark.parametrize('text,intent,old,new',[
 ('wenshu分组改名mircrosung','rename_group','wenshu','mircrosung'),
 ('把 wenshu 分组重命名为 新项目','rename_group','wenshu','新项目'),
 ('删除分组 项目A','delete_group','项目A',None),
 ('项目A分组删除','delete_group','项目A',None)])
def test_group_conversation_resolves_exact_existing_group(rules_cli,text,intent,old,new):
    c=json.loads(run(rules_cli,'group-command',text))
    assert c['intent']==intent and c['patch']['groupId']==old and c['requiresConfirmation']
    assert c['patch'].get('newGroupId')==new


def test_feedback_hint_is_separate_and_does_not_strip_task_content(rules_cli):
    title='任务标题里包含回复这个词'
    text=f'共 1 项\n\n1、{title}\n   等待 · 收件箱\n\n回复「任务编号 + 操作」，如：任务5标记完成。'
    s=json.loads(run(rules_cli,'feedback',text))
    assert title in s['content'] and '任务5标记完成' not in s['content']
    assert s['hint'].startswith('回复「')


def test_legacy_cloud_local_profiles_migrate_without_loss(rules_cli):
    value=json.loads(run(rules_cli,'profiles'))
    assert value==dict(count=2,cloud='existing-cloud',local='existing-local',selected='legacy-local')


def test_explicit_group_scopes_query_when_model_omits_filter(rules_cli):
    assert run(rules_cli,'scope','请帮我看看 POC交互验证 里尚未完成的安排有哪些？')=='POC交互验证'
    assert run(rules_cli,'scope','查询全部待办')=='nil'


@pytest.mark.parametrize('offset,status,expected',[
 (0,'todo','due'),(-30,'todo','due'),(30,'todo','skip'),(-61,'todo','skip'),
 (0,'done','skip'),(0,'deleted','skip'),(0,'conflicted','skip'),(0,'cancelled','skip')])
def test_bark_due_policy_excludes_old_or_ineligible_tasks(rules_cli,offset,status,expected):
    assert run(rules_cli,'bark',str(offset),status)==expected


@pytest.mark.parametrize('text',[
 '当前模型是什么','当前大模型是什么','查看当前使用的模型','现在是什么模型','现在是什么大模型？','当前使用的大模型是什么','查看当前大模型','你现在使用的是哪个模型？','模型列表','请帮我查看模型','切换大模型'])
def test_natural_model_queries_bypass_task_ai(rules_cli,text):assert run(rules_cli,'model-control',text)=='query'

@pytest.mark.parametrize('text,result',[
 ('把当前大模型切换成本地','select:local'),('切换模型2','select:local'),('切换到本地大模型','select:local'),
 ('切换大模型为云端','select:cloud'),('更换为云端模型','select:cloud'),
 ('使用模型 本地 Ollama','select:local'),('切换模型 qwen3.8-flash','select:cloud'),
 ('换成模型2','select:local'),('切换模型999','unmatched'),
 ('新增任务：优化模型列表','nil'),('genetron: zhiyu大模型提示词优化','nil'),
 ('更换任务日期','nil')])
def test_model_switch_aliases_and_unrelated_text(rules_cli,text,result):assert run(rules_cli,'model-control',text)==result

@pytest.mark.parametrize('input,title,expected,group',[
 ('genetron: zhiyu大模型提示词优化','genetron: zhiyu大模型提示词优化','zhiyu大模型提示词优化','genetron'),
 ('新增一个任务：genetron: zhiyu大模型提示词优化','genetron: zhiyu大模型提示词优化','zhiyu大模型提示词优化','genetron'),
 ('GENETRON： zhiyu大模型提示词优化','GENETRON： zhiyu大模型提示词优化','zhiyu大模型提示词优化','genetron'),
 ('genetron: zhiyu大模型提示词优化','zhiyu大模型提示词优化','zhiyu大模型提示词优化','genetron'),
 ('未知分组: 任务内容','未知分组: 任务内容','未知分组: 任务内容','inbox'),
 ('整理 https://example.test','整理 https://example.test','整理 https://example.test','inbox'),
 ('任务标题：genetron: 说明','genetron: 说明','genetron: 说明','inbox')])
def test_explicit_known_group_prefix_is_not_part_of_new_title(rules_cli,input,title,expected,group):
    c=json.loads(run(rules_cli,'creation-prefix',input,title))
    assert c==dict(title=expected,groupId=group)


def test_creation_cleanup_never_renames_existing_tasks(rules_cli):
    c=json.loads(run(rules_cli,'creation-prefix','genetron: 保留','genetron: 保留','update_task'))
    assert c==dict(title='genetron: 保留',groupId='inbox')


@pytest.mark.parametrize('lens,expected',[('active','a,b,c'),('doing','b'),('waiting','c'),('completed','d')])
def test_reference_board_statuses_exclude_deleted_archived_cancelled(rules_cli,lens,expected):
    assert run(rules_cli,'board',lens)==expected

@pytest.mark.parametrize('lens',['active','doing','waiting','completed'])
def test_reference_board_keeps_group_intersection(rules_cli,lens):
    assert run(rules_cli,'board',lens,'other-group')==''

def test_reference_board_trash_retains_recoverable_task(rules_cli):
    assert run(rules_cli,'board','completed','all','trash')=='f'

def test_reference_board_all_retains_cancelled_and_completed(rules_cli):
    assert run(rules_cli,'board','active','all','all-statuses')=='a,b,c,e,d'


@pytest.mark.parametrize('count,expanded',[(0,False),(1,False),(10,False),(11,False),(25,False),(11,True),(25,True)])
def test_inline_list_page_threshold_and_order(rules_cli,count,expanded):
    expected=list(range(count if expanded else min(count,10)))
    assert run(rules_cli,'page',str(count),'expanded' if expanded else 'collapsed')==','.join(map(str,expected))
