"""Actual Swift snapshot/backup boundary with temporary storage. No personal Reminders access."""
import os
import subprocess
from pathlib import Path
import pytest

ROOT = Path(__file__).resolve().parents[1]

@pytest.fixture(scope="session")
def backup_cli(tmp_path_factory):
    folder = tmp_path_factory.mktemp("taskcat-backup")
    # Compile the production persistence implementation without the app/network clients.
    persistence = folder / "Persistence.swift"
    persistence.write_text((ROOT / "apps/macos/Sources/Infrastructure.swift").read_text().split("struct SecretStore")[0])
    main = folder / "Main.swift"
    main.write_text(r'''import Foundation
import EventKit
@main struct Probe {
 static func main() throws {
  let mode=CommandLine.arguments[1]
  let id="00000000-0000-4000-8000-000000000001",oid="00000000-0000-4000-8000-000000000002"
  let task=ManagedTask(id:id,title:"POC snapshot",notes:"line1\nline2",group:.inbox,status:"doing",progress:40,dueAt:Date(timeIntervalSince1970:1800000000),completed:false,softDeleted:false,archived:false,conflicted:false)
  let store=EKEventStore(),row=EKReminder(eventStore:EKEventStore())
  row.title=task.title;row.notes=task.notes;row.priority=5;row.location="POC location"
  var cal=Calendar(identifier:.gregorian);cal.timeZone=TimeZone(secondsFromGMT:0)!
  row.dueDateComponents=cal.dateComponents([.year,.month,.day,.hour,.minute],from:task.dueAt!)
  row.startDateComponents=row.dueDateComponents;row.addAlarm(EKAlarm(absoluteDate:task.dueAt!))
  if mode=="repeat" {row.addRecurrenceRule(EKRecurrenceRule(recurrenceWith:.weekly,interval:1,end:nil))}
  if mode=="location" {let a=EKAlarm(relativeOffset:0);a.structuredLocation=EKStructuredLocation(title:"POC");row.addAlarm(a)}
  do {
   let snapshot=try TaskSnapshot(task:task,reminder:row)
   let op=MetadataOperation(schemaVersion:1,operationId:oid,entityType:"task",entityId:id,actorId:id,parents:[],createdAt:"2026-10-25T00:00:00Z",source:"poc",summary:"snapshot",patch:["status":.text("doing"),"softDeleted":.flag(false),"archived":.flag(false)])
   var backup=TaskBackup(snapshots:[snapshot],trash:[],operations:[op],numbers:TaskNumbers(values:[id:7]))
   if mode=="duplicate" {backup.snapshots.append(snapshot)}
   if mode=="missing-log" {backup.operations=[]}
   if mode=="missing-parent" {backup.operations=[MetadataOperation(schemaVersion:1,operationId:oid,entityType:"task",entityId:id,actorId:id,parents:["00000000-0000-4000-8000-000000000003"],createdAt:op.createdAt,source:"poc",summary:"child",patch:op.patch)]}
   if mode=="number-collision" {backup.numbers.values[oid]=7}
   let data=try backup.encoded()
   if mode=="corrupt" {
    var object=try JSONSerialization.jsonObject(with:data) as! [String:Any];object["sha256"]="invalid"
    _=try TaskBackup.decode(JSONSerialization.data(withJSONObject:object));fatalError("accepted corruption")
   }
   let decoded=try TaskBackup.decode(data)
   var existing:[String:MetadataOperation]=[:]
   if mode=="operation-collision" {existing[oid]=MetadataOperation(schemaVersion:1,operationId:oid,entityType:"task",entityId:id,actorId:id,parents:[],createdAt:op.createdAt,source:"poc",summary:"collision",patch:["status":.text("done")])}
   _=try decoded.mergedProjection(existing:existing)
   if mode=="snapshot" {
    let copy=EKReminder(eventStore:store);decoded.snapshots[0].fill(copy)
    assert(copy.title==row.title && copy.notes==row.notes && copy.priority==5 && copy.location==row.location)
    // EventKit normalizes absent era/seconds to 1/0; compare scheduled instants.
    assert(cal.date(from:copy.dueDateComponents!)==cal.date(from:row.dueDateComponents!))
    assert(cal.date(from:copy.startDateComponents!)==cal.date(from:row.startDateComponents!))
    assert(copy.alarms?.first?.absoluteDate==task.dueAt && decoded.numbers.values[id]==7)
   }
   if mode=="trash" || mode=="path" || mode=="bad-trash" {
    let dir=URL(fileURLWithPath:CommandLine.arguments[2]);let trash=try TaskTrashStore(directory:dir)
    try trash.save(TrashEntry(operationID:oid,snapshot:snapshot))
    let loaded=try trash.load(id);assert(loaded?.snapshot.task==task)
    if mode=="path" {_=try trash.load("../outside")}
    if mode=="bad-trash" {try Data("broken".utf8).write(to:dir.appendingPathComponent(id+".json"));_=try trash.load(id)}
    try trash.remove(id);let remaining=try trash.all();assert(remaining.isEmpty)
   }
   if mode=="selection" {
    var tasks=(0..<160).map{n -> ManagedTask in var t=task;t=ManagedTask(id:String(format:"00000000-0000-4000-8000-%012d",n+10),title:"unrelated \(n)",notes:"",group:.inbox,status:"todo",progress:nil,dueAt:nil,completed:false,softDeleted:false,archived:false,conflicted:false);return t}
    tasks.append(task)
    assert(ModelContextSelection.select(tasks,input:"POC snapshot 改到明天",numbers:backup.numbers).first?.id==id)
    assert(ModelContextSelection.select(tasks,input:"任务7改到明天",numbers:backup.numbers).first?.id==id)
   }
   if mode=="timezone" {print(DateSuggestion.localCalendar.timeZone.identifier);return}
   print("passed")
  } catch {print("rejected");exit(2)}
 }
}''')
    binary = folder / "probe"
    sources = ["Domain", "ConversationLogic", "TaskBoard", "NotificationRules", "TaskSnapshots", "TaskBackup"]
    result = subprocess.run(["swiftc", "-parse-as-library", "-swift-version", "5", str(ROOT / "poc/metadata-journal/OperationJournal.swift"), str(persistence), *[str(ROOT / f"apps/macos/Sources/{name}.swift") for name in sources], str(main), "-o", str(binary)], capture_output=True, text=True, timeout=120)
    assert result.returncode == 0, result.stderr
    return binary

@pytest.mark.parametrize("mode", ["snapshot", "trash", "selection"])
def test_roundtrip_and_relevant_target(backup_cli, tmp_path, mode):
    r = subprocess.run([str(backup_cli), mode, str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == "passed"

@pytest.mark.parametrize("mode", ["duplicate", "missing-log", "missing-parent", "number-collision", "corrupt", "operation-collision", "repeat", "location", "path", "bad-trash"])
def test_refuse_lossy_or_invalid_restore(backup_cli, tmp_path, mode):
    r = subprocess.run([str(backup_cli), mode, str(tmp_path)], capture_output=True, text=True)
    assert r.returncode == 2, r.stderr
    assert r.stdout.strip() == "rejected"

@pytest.mark.parametrize("tz", ["America/Los_Angeles", "Europe/London", "Asia/Singapore"])
def test_timezone_follows_device(backup_cli, tz):
    r = subprocess.run([str(backup_cli), "timezone"], env={**os.environ, "TZ": tz}, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    assert r.stdout.strip() == tz
