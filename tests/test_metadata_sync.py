"""Exercise the real immutable sync implementation in isolated two-device directories."""
import subprocess
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture(scope='session')
def sync_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('sync-contract')
    persistence=folder/'Persistence.swift'
    persistence.write_text((ROOT/'apps/macos/Sources/Infrastructure.swift').read_text().split('struct SecretStore')[0])
    main=folder/'Main.swift'
    main.write_text(r'''import Foundation
import CryptoKit
@main struct Probe {
 static func main() throws {
  let mode=CommandLine.arguments[1],root=URL(fileURLWithPath:CommandLine.arguments[2])
  let store=SharedMetadataStore(directory:root)
  let a="00000000-0000-4000-8000-000000000001",b="00000000-0000-4000-8000-000000000002"
  let task="00000000-0000-4000-8000-000000000010",other="00000000-0000-4000-8000-000000000011"
  func op(_ id:String,_ entity:String,_ actor:String,_ parents:[String],_ patch:[String:FieldValue])->MetadataOperation {
   MetadataOperation(schemaVersion:1,operationId:id,entityType:"task",entityId:entity,actorId:actor,parents:parents.sorted(),createdAt:"2026-10-26T00:00:00Z",source:"poc",summary:"synthetic sync",patch:patch)
  }
  let create=op(task,task,a,[],["status":.text("doing"),"progress":.number(40),"softDeleted":.flag(false),"archived":.flag(false)])
  try store.initialize(actor:a,numbers:[task:7]);try store.register(actor:b)
  let first=try store.exchange(actor:a,operations:[task:create],numbers:[task:7],trash:[])
  let second=try store.exchange(actor:b,operations:[:],numbers:[task:7],trash:[])
  assert(second.operations[task]==create && second.numbers[task]==7 && second.lane==1 && first.lane==0)
  var rejected=false
  do {
   if mode=="bootstrap" {assert(second.operations[task]?.patch["progress"] == .number(40))}
   if mode=="new-task" || mode=="wrong-lane" || mode=="number-collision" {
    let c=op(other,other,b,[task],["status":.text("todo")])
    let n=mode=="wrong-lane" ? 20 : mode=="number-collision" ? 7 : 1001
    _=try store.exchange(actor:b,operations:[task:create,other:c],numbers:[task:7,other:n],trash:[])
    let received=try store.exchange(actor:a,operations:[task:create],numbers:[task:7],trash:[])
    assert(received.operations[other]==c && received.numbers[other]==1001)
   }
   if mode=="operation-collision" {
    let changed=op(task,task,a,[],["status":.text("done")])
    _=try store.exchange(actor:b,operations:[task:changed],numbers:[task:7],trash:[])
   }
   if mode=="missing-parent" {
    let c=op(other,task,b,["00000000-0000-4000-8000-000000000099"],["progress":.number(50)])
    _=try store.exchange(actor:b,operations:[other:c],numbers:[task:7],trash:[])
   }
   if mode=="corrupt" {
    let file=try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("packets"),includingPropertiesForKeys:nil).first!
    try Data("corrupt".utf8).write(to:file)
    _=try store.exchange(actor:b,operations:[:],numbers:[task:7],trash:[])
   }
   if mode=="device-collision" {
    let c="00000000-0000-4000-8000-000000000003"
    let payload=try JSONEncoder().encode(SyncDevice(actor:c,lane:1))
    let digest=SHA256.hash(data:payload).map{String(format:"%02x",$0)}.joined()
    let data=try JSONSerialization.data(withJSONObject:["payload":payload.base64EncodedString(),"digest":digest])
    try data.write(to:root.appendingPathComponent("devices/"+c+".json"))
    _=try store.exchange(actor:b,operations:[:],numbers:[task:7],trash:[])
   }
   if mode=="concurrent-progress" {
    let x="00000000-0000-4000-8000-000000000020",y="00000000-0000-4000-8000-000000000021"
    let left=op(x,task,a,[task],["progress":.number(50)]),right=op(y,task,b,[task],["progress":.number(60)])
    _=try store.exchange(actor:a,operations:[task:create,x:left],numbers:[task:7],trash:[])
    let result=try store.exchange(actor:b,operations:[task:create,y:right],numbers:[task:7],trash:[])
    let j=try OperationJournal(directory:root.appendingPathComponent("check"))
    for value in result.operations.values {_=try j.append(value)}
    let projection=try j.project();assert(!projection.causallyCompleteAndConflictFree)
    assert(projection.entities.first?.conflicts["progress"]?.count==2)
   }
   if mode=="offline-numbers" {
    var x=TaskNumbers(values:[task:7],lane:0),y=TaskNumbers(values:[task:7],lane:1)
    try x.reserve(other);try y.reserve(other)
    assert(x.values[other]==8 && y.values[other]==1001)
    x.assign([ManagedTask(id:a,title:"unknown",notes:"",group:.inbox,status:"todo",progress:nil,dueAt:nil,completed:false,softDeleted:false,archived:false,conflicted:false)])
    assert(x.values[a]==nil)
   }
  } catch {rejected=true}
  let expected=["wrong-lane","number-collision","operation-collision","missing-parent","corrupt","device-collision"].contains(mode)
  assert(rejected==expected)
  print("pass")
 }
}
''')
    sources=['Domain','ConversationLogic','TaskBoard','NotificationRules','TaskSnapshots','TaskBackup','MetadataSync']
    binary=folder/'probe'
    r=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'poc/metadata-journal/OperationJournal.swift'),str(persistence),*[str(ROOT/f'apps/macos/Sources/{s}.swift') for s in sources],str(main),'-o',str(binary)],capture_output=True,text=True,timeout=120)
    assert r.returncode==0,r.stderr
    return binary

@pytest.mark.parametrize('mode',['bootstrap','new-task','wrong-lane','number-collision','operation-collision','missing-parent','corrupt','device-collision','concurrent-progress','offline-numbers'])
def test_real_sync_contract(sync_cli,tmp_path,mode):
    r=subprocess.run([str(sync_cli),mode,str(tmp_path/'shared')],capture_output=True,text=True,timeout=30)
    assert r.returncode==0,r.stderr
    assert r.stdout.strip()=='pass'
