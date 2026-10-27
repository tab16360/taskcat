"""Which request records may leave the scanned folder; pure Swift rule, synthetic records only."""
import json,subprocess
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]

@pytest.fixture(scope='session')
def retention_cli(tmp_path_factory):
    folder=tmp_path_factory.mktemp('retention')
    main=folder/'Main.swift'
    main.write_text(r'''import Foundation
@main struct Probe {
 static func main() throws {
  let rows=try JSONSerialization.jsonObject(with:Data(CommandLine.arguments[2].utf8)) as! [[String:Any]]
  let items=rows.map{RequestRetention.Item(id:$0["id"] as! String,phase:$0["phase"] as! String,createdAt:$0["createdAt"] as! String,source:$0["source"] as! String,confirmationNumber:$0["n"] as? Int)}
  let now=ISO8601DateFormatter().date(from:"2026-10-27T00:00:00Z")!
  if CommandLine.arguments[1]=="archive" {print(RequestRetention.archivable(items,now:now).sorted().joined(separator:","))}
  else {print(String(data:try JSONSerialization.data(withJSONObject:RequestRetention.counters(items,merging:["wechat:a":9]),options:.sortedKeys),encoding:.utf8)!)}
 }
}
''')
    binary=folder/'retention'
    result=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'apps/macos/Sources/RequestRetention.swift'),str(main),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert result.returncode==0,result.stderr
    return binary

def record(i,phase='applied',days_ago=30,source='menu',n=None):
    day=27-days_ago if days_ago<27 else 1
    month='10' if days_ago<27 else '09'
    return dict(id=f'r{i:04d}',phase=phase,createdAt=f'2026-{month}-{day:02d}T00:00:{i%60:02d}Z',source=source,n=n)

def run(cli,mode,rows):
    out=subprocess.check_output([str(cli),mode,json.dumps(rows)],text=True,timeout=10).strip()
    return out.split(',') if mode=='archive' and out else (json.loads(out) if mode=='counters' else [])

def test_small_folder_keeps_everything(retention_cli):
    assert run(retention_cli,'archive',[record(i) for i in range(150)])==[]

def test_only_old_finished_records_beyond_the_newest_200_move(retention_cli):
    old=[record(i,days_ago=40) for i in range(240)]          # 240 finished, all old
    recent=[record(1000+i,days_ago=1) for i in range(5)]    # newest, always kept
    unfinished=[record(2000,phase='awaiting_confirmation',days_ago=60),record(2001,phase='uncertain',days_ago=60),record(2002,phase='applying',days_ago=60)]
    moved=set(run(retention_cli,'archive',old+recent+unfinished))
    assert len(moved)==45                                    # 245 finished - 200 kept
    assert not moved & {'r2000','r2001','r2002'} and not moved & {f'r{1000+i:04d}' for i in range(5)}

def test_recent_records_stay_even_when_many(retention_cli):
    assert run(retention_cli,'archive',[record(i,days_ago=3) for i in range(300)])==[]

def test_counters_keep_the_highest_number_per_source(retention_cli):
    rows=[record(1,source='wechat:a',n=4),record(2,source='wechat:a',n=12),record(3,source='menu',n=2),record(4,source='menu')]
    assert run(retention_cli,'counters',rows)=={'menu':2,'wechat:a':12}
    assert run(retention_cli,'counters',[record(1,source='wechat:a',n=3)])=={'wechat:a':9}
