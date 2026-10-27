"""Worker boundary tests use real local sockets/files, never WeChat credentials or APIs."""
import importlib.util,json,os,socket,threading,uuid,tempfile
from pathlib import Path
import pytest
ROOT=Path(__file__).resolve().parents[1]
# The third-party SDK is optional and not distributed; CI runs without it.
needs_sdk=pytest.mark.skipif(importlib.util.find_spec('wechat_clawbot_sdk') is None,reason='optional WeChat SDK not installed')

@pytest.fixture
def worker(tmp_path,monkeypatch):
    spec=importlib.util.spec_from_file_location('tasksecretary_worker',ROOT/'services/wechat-bridge/run_worker.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    short=tempfile.TemporaryDirectory(prefix='ts-',dir='/tmp')
    module.ROOT=tmp_path/'wechat';module.RUNTIME=Path(short.name)/'r';module.RUNTIME.mkdir()
    (module.RUNTIME/'command-token.json').write_text(json.dumps('SYNTHETIC_LOCAL_TEST_TOKEN'))
    yield module
    short.cleanup()

@pytest.mark.parametrize('status',['applied','busy','awaiting_confirmation'])
def test_real_local_socket_preserves_request_identity_and_chinese(worker,status):
    path=worker.RUNTIME/'command.sock';request_id=str(uuid.uuid4());seen=[]
    listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(str(path));listener.listen(1)
    def peer():
        conn,_=listener.accept()
        with conn,conn.makefile('rb') as file:
            message=json.loads(file.readline());seen.append(message)
            conn.sendall(json.dumps({'ok':status!='busy','status':status,'message':'合成测试结果','requestId':request_id}).encode()+b'\n')
        listener.close()
    thread=threading.Thread(target=peer);thread.start()
    result=worker.request_service('打印模板做到一半了',request_id,'SYNTHETIC_CONVERSATION')
    thread.join(timeout=5)
    assert not thread.is_alive() and result['status']==status
    assert seen[0]['requestId']==request_id and seen[0]['text']=='打印模板做到一半了'
    assert seen[0]['token']=='SYNTHETIC_LOCAL_TEST_TOKEN'


def test_response_for_other_request_is_rejected(worker):
    path=worker.RUNTIME/'command.sock'
    listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind(str(path));listener.listen(1)
    def peer():
        conn,_=listener.accept()
        with conn,conn.makefile('rb') as file:
            json.loads(file.readline());conn.sendall(b'{"requestId":"wrong","ok":true}\n')
        listener.close()
    thread=threading.Thread(target=peer);thread.start()
    with pytest.raises(RuntimeError):worker.request_service('test',str(uuid.uuid4()),'synthetic')
    thread.join(timeout=5)


def test_atomic_private_state_replaces_old_permissions(worker):
    file=worker.ROOT/'state.json'
    worker.atomic_json(file,{'cursor':'SYNTHETIC_1'})
    assert file.stat().st_mode&0o777==0o600
    os.chmod(file,0o644)
    worker.atomic_json(file,{'cursor':'SYNTHETIC_2'})
    assert file.stat().st_mode&0o777==0o600 and json.loads(file.read_text())['cursor']=='SYNTHETIC_2'
    assert not list(file.parent.glob('.stage-*'))


@pytest.mark.parametrize('payload,valid',[
 ({'ret':0,'msgs':[]},True),({'get_updates_buf':'SYNTHETIC_CURSOR','msgs':[]},True),
 ({},False),({'get_updates_buf':123,'msgs':[]},False),
 ({'get_updates_buf':'C','msgs':'invalid'},False)])
def test_raw_protocol_optional_ret_requires_valid_response_shape(worker,payload,valid):
    if valid:assert worker.decode_poll_payload(payload,'OLD')[0] in (0,None)
    else:
        with pytest.raises(ValueError):worker.decode_poll_payload(payload,'OLD')


def test_expired_session_never_becomes_a_successful_batch(worker):
    code,messages,cursor=worker.decode_poll_payload({'errcode':-14,'msgs':[]},'UNCHANGED')
    assert code==-14 and cursor=='UNCHANGED' and messages==[]


@needs_sdk
def test_plain_reply_preserves_numbered_paragraphs_without_sdk_markdown(worker):
    import asyncio
    from types import SimpleNamespace
    sent=[]
    class HTTP:
        async def post(self,url,**kwargs):
            sent.append((url,json.loads(kwargs['content'])))
            return SimpleNamespace(raise_for_status=lambda:None,json=lambda:{'ret':0})
    account=SimpleNamespace(base_url='https://synthetic.weixin.qq.com',bot_token='SYNTHETIC_TOKEN',route_tag=None)
    text='共 2 项\n\n1、合成_任务_A\n   待办 · 收件箱\n\n5、合成_任务_B\n\n回复：任务5标记完成'
    asyncio.run(worker.send_plain_reply(HTTP(),account,'SYNTHETIC_USER','SYNTHETIC_CONTEXT',text))
    assert sent[0][0].endswith('/ilink/bot/sendmessage')
    assert sent[0][1]['msg']['item_list'][0]['text_item']['text']==text


@needs_sdk
def test_reply_rejection_is_not_acknowledged_as_success(worker):
    import asyncio
    from types import SimpleNamespace
    class HTTP:
        async def post(self,*args,**kwargs):
            return SimpleNamespace(raise_for_status=lambda:None,json=lambda:{'errcode':-14})
    account=SimpleNamespace(base_url='https://synthetic.weixin.qq.com',bot_token='SYNTHETIC_TOKEN',route_tag=None)
    with pytest.raises(RuntimeError):asyncio.run(worker.send_plain_reply(HTTP(),account,'SYNTHETIC_USER','SYNTHETIC_CONTEXT','合成'))


def test_status_identifies_its_own_worker(worker):
    worker.status('connected',poll_verified=True)
    status=json.loads((worker.ROOT/'status.json').read_text())
    assert status['worker_pid']==os.getpid() and status['owner_pid']==os.getppid()


def test_owner_exit_cancels_and_cleans_up_worker(worker,monkeypatch):
    import asyncio
    from types import SimpleNamespace
    seen=[]
    async def scenario():
        ready=asyncio.Event()
        async def work(args):
            try:ready.set();await asyncio.Event().wait()
            finally:seen.append('cleanup')
        async def watch(pid):await ready.wait()
        monkeypatch.setattr(worker,'run',work);monkeypatch.setattr(worker,'wait_for_owner_exit',watch)
        assert await worker.supervise(SimpleNamespace(parent_pid=os.getppid()))==0
    asyncio.run(scenario())
    assert seen==['cleanup'] and json.loads((worker.ROOT/'status.json').read_text())['state']=='owner_exited'


def test_worker_exit_preserves_error_and_cancels_watch(worker,monkeypatch):
    import asyncio
    from types import SimpleNamespace
    seen=[]
    async def scenario():
        async def work(args):await asyncio.sleep(0);raise ValueError('synthetic')
        async def watch(pid):
            try:await asyncio.Event().wait()
            finally:seen.append('watch-cleanup')
        monkeypatch.setattr(worker,'run',work);monkeypatch.setattr(worker,'wait_for_owner_exit',watch)
        with pytest.raises(ValueError,match='synthetic'):await worker.supervise(SimpleNamespace(parent_pid=os.getppid()))
    asyncio.run(scenario());assert seen==['watch-cleanup']


def test_missing_owner_does_not_start_worker(worker,monkeypatch):
    import asyncio
    from types import SimpleNamespace
    async def work(args):raise AssertionError('must not start')
    monkeypatch.setattr(worker,'run',work)
    assert asyncio.run(worker.supervise(SimpleNamespace(parent_pid=-1)))==0


@needs_sdk
def test_lock_loser_cli_does_not_corrupt_live_worker_status(tmp_path):
    import subprocess,sys,fcntl
    runtime=tmp_path/'.tasksecretary/runtime';runtime.mkdir(parents=True)
    root=tmp_path/'.tasksecretary/wechat';root.mkdir()
    status=root/'status.json';original={'state':'connected','worker_pid':123456};status.write_text(json.dumps(original))
    with (runtime/'wechat-worker.lock').open('w') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        result=subprocess.run([sys.executable,str(ROOT/'services/wechat-bridge/run_worker.py'),'--old-owner-stopped'],env={**os.environ,'HOME':str(tmp_path)},capture_output=True,text=True,timeout=10)
    assert result.returncode==3,result.stderr
    assert json.loads(status.read_text())==original

def test_worker_environment_drops_only_socks_all_proxy(tmp_path):
    import subprocess
    main=tmp_path/'EnvMain.swift'
    main.write_text(r'''import Foundation
@main struct EnvProbe {static func main() {
 let env=WeChatEnvironment.worker(["all_proxy":"socks5://127.0.0.1:7897","ALL_PROXY":"SOCKS5H://h:1","https_proxy":"http://127.0.0.1:7897","HOME":"/h"])
 let kept=WeChatEnvironment.worker(["all_proxy":"http://127.0.0.1:7897"])
 print(env.keys.sorted().joined(separator:","),kept["all_proxy"] ?? "nil")
}}
''')
    binary=tmp_path/'env'
    result=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',str(ROOT/'apps/macos/Sources/WeChatEnvironment.swift'),str(main),'-o',str(binary)],capture_output=True,text=True,timeout=90)
    assert result.returncode==0,result.stderr
    assert subprocess.check_output([str(binary)],text=True).strip()=='HOME,https_proxy http://127.0.0.1:7897'

def test_failure_is_logged_with_type_and_location(tmp_path):
    import subprocess,sys
    # -S hides site-packages, so the worker's lazy `import httpx` fails like a broken runtime would.
    result=subprocess.run([sys.executable,'-S',str(ROOT/'services/wechat-bridge/run_worker.py'),'--old-owner-stopped'],
        env={'HOME':str(tmp_path),'PATH':'/usr/bin:/bin'},capture_output=True,text=True,timeout=20)
    assert result.returncode==2
    line=result.stderr.strip().splitlines()[-1]
    assert 'worker stopped: ModuleNotFoundError' in line and "No module named 'httpx'" in line and 'run_worker.py:' in line
    status=json.loads((tmp_path/'.tasksecretary/wechat/status.json').read_text())
    assert status['state']=='blocked' and status['error_type']=='ModuleNotFoundError'
