"""Actual local SQLite/process crash tests; not real WeChat or CloudKit results."""
import os,sqlite3,subprocess,sys
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'services/wechat-bridge/src'
sys.path.insert(0,str(SRC))
from tasksecretary_bridge.inbox import DurableInbox
MESSAGE={'message_id':1,'from_user_id':'POC_SENDER','item_list':[]}

def test_entire_batch_and_cursor_survive_reopen(tmp_path):
    path=tmp_path/'inbox.sqlite';s=DurableInbox(path)
    ops=s.commit_batch('POC_ACCOUNT',[MESSAGE,dict(MESSAGE,message_id=2)],'CURSOR_2');s.close()
    s=DurableInbox(path);assert s.cursor('POC_ACCOUNT')=='CURSOR_2'
    assert [op for op,_ in s.pending('POC_ACCOUNT')]==ops
    assert path.stat().st_mode&0o777==0o600;s.close()

def test_replay_preserves_operation_and_ack(tmp_path):
    s=DurableInbox(tmp_path/'inbox.sqlite');ops=s.commit_batch('POC_ACCOUNT',[MESSAGE],'C1')
    s.acknowledge(ops[0]);assert s.commit_batch('POC_ACCOUNT',[MESSAGE],'C2')==ops
    assert not s.pending('POC_ACCOUNT');assert s.cursor('POC_ACCOUNT')=='C2';s.close()

def test_missing_id_never_advances_cursor(tmp_path):
    s=DurableInbox(tmp_path/'inbox.sqlite')
    with pytest.raises(ValueError):s.commit_batch('POC_ACCOUNT',[{'from_user_id':'POC_SENDER'}],'UNSAFE')
    assert s.cursor('POC_ACCOUNT')=='' and s.pending('POC_ACCOUNT')==[];s.close()

@pytest.mark.parametrize('when,exit_code,expected_cursor,expected_pending',[
    ('before_cursor',91,'',0),('after_commit',92,'C1',1)])
def test_real_process_exit_at_batch_barrier(tmp_path,when,exit_code,expected_cursor,expected_pending):
    path=tmp_path/'inbox.sqlite'
    code='''import sys,os
sys.path.insert(0,sys.argv[1])
from tasksecretary_bridge.inbox import DurableInbox
s=DurableInbox(sys.argv[2])
if sys.argv[3]=='before_cursor':
 s.db.create_function('poc_crash',0,lambda:os._exit(91))
 s.db.execute("CREATE TEMP TRIGGER stop_before_cursor BEFORE INSERT ON cursors BEGIN SELECT poc_crash(); END")
s.commit_batch('POC_ACCOUNT',[{'message_id':1,'from_user_id':'POC_SENDER'}],'C1')
os._exit(92)
'''
    child=subprocess.run([sys.executable,'-c',code,str(SRC),str(path),when],capture_output=True,text=True,timeout=10)
    assert child.returncode==exit_code
    s=DurableInbox(path);assert s.cursor('POC_ACCOUNT')==expected_cursor
    assert len(s.pending('POC_ACCOUNT'))==expected_pending;s.close()
