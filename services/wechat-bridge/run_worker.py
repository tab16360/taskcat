#!/usr/bin/env python3
"""Single-node development worker. Both entrances call the same native TaskService.
No SDK poll_events: raw batches and cursor enter DurableInbox before dispatch.
"""
import argparse,asyncio,contextlib,fcntl,hashlib,json,logging,os,socket,sys,tempfile,time,uuid
from pathlib import Path
from urllib.parse import urljoin,urlsplit
sys.path.insert(0,str(Path(__file__).resolve().parent/'src'))
from tasksecretary_bridge.inbox import DurableInbox

ROOT=Path.home()/'.tasksecretary/wechat'
RUNTIME=Path.home()/'.tasksecretary/runtime'

def atomic_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,temp=tempfile.mkstemp(prefix='.stage-',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as f:json.dump(value,f,ensure_ascii=False);f.flush();os.fsync(f.fileno())
        os.replace(temp,path)
        directory=os.open(path.parent,os.O_RDONLY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if os.path.exists(temp):os.unlink(temp)

def status(state,**extra):
    atomic_json(ROOT/'status.json',dict(state=state,worker_pid=os.getpid(),owner_pid=os.getppid(),recorded_at_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),**extra))

class WorkerAlreadyRunning(RuntimeError):pass

# Messages of these types describe the environment (missing package, path, socket), never
# user content; anything else is logged by type and code location only.
SAFE_DETAIL=(ImportError,OSError)
def report_failure(exc):
    import traceback
    frames=' <- '.join(f'{Path(f.filename).name}:{f.lineno} {f.name}' for f in reversed(traceback.extract_tb(exc.__traceback__)[-4:]))
    detail=': '+str(exc).splitlines()[0][:200] if isinstance(exc,SAFE_DETAIL) and str(exc) else ''
    print(f"{time.strftime('%Y-%m-%d %H:%M:%S')} worker stopped: {type(exc).__name__}{detail} at {frames}",file=sys.stderr,flush=True)

async def wait_for_owner_exit(pid):
    while os.getppid()==pid:await asyncio.sleep(1)

async def supervise(args):
    owner=getattr(args,'parent_pid',None)
    if owner is None:return await run(args)
    if os.getppid()!=owner:return 0
    work=asyncio.create_task(run(args));watch=asyncio.create_task(wait_for_owner_exit(owner))
    try:
        done,_=await asyncio.wait({work,watch},return_when=asyncio.FIRST_COMPLETED)
        if work in done:return await work
        work.cancel()
        with contextlib.suppress(asyncio.CancelledError):await work
        status('owner_exited');return 0
    finally:
        watch.cancel();work.cancel()
        await asyncio.gather(watch,work,return_exceptions=True)

def request_service(text,request_id,conversation):
    token=json.loads((RUNTIME/'command-token.json').read_text())
    payload=dict(token=token,requestId=request_id,source='wechat:'+conversation,text=text)
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
        client.settimeout(75);client.connect(str(RUNTIME/'command.sock'))
        client.sendall(json.dumps(payload,ensure_ascii=False).encode()+b'\n')
        with client.makefile('rb') as f:line=f.readline(65537)
    if len(line)>65536 or not line:raise RuntimeError('invalid local response')
    result=json.loads(line)
    if result.get('requestId')!=request_id:raise RuntimeError('mismatched request')
    return result

def decode_poll_payload(payload,previous_cursor):
    if not isinstance(payload,dict):raise ValueError('invalid poll envelope')
    code=payload.get('errcode') if payload.get('errcode') not in (None,0) else payload.get('ret')
    if code not in (None,0):return code,[],previous_cursor
    cursor=payload.get('get_updates_buf',previous_cursor)
    messages=payload.get('msgs')
    if messages is None:messages=[]
    if not isinstance(cursor,str) or not isinstance(messages,list):raise ValueError('invalid poll batch')
    # The real API may omit ret. Accept a structured cursor response, never an empty
    # object or a synthetic SDK timeout-success. HTTP timeouts never reach this function.
    if code is None and not isinstance(payload.get('get_updates_buf'),str):raise ValueError('missing poll result')
    return code,messages,cursor

async def send_plain_reply(http,account,user_id,context_token,text):
    """Keep numbered paragraphs and literal task names intact; skip SDK Markdown rewrite."""
    from wechat_clawbot_sdk.messaging.service import build_text_message_request,generate_client_id
    from wechat_clawbot_sdk.api.headers import build_base_info,build_json_headers,encode_json_body
    from wechat_clawbot_sdk.api.encoding import to_wire_dict
    plain=str(text).replace('\r\n','\n')
    if len(plain)>1800:plain=plain[:1700]+'\n\n内容较长，请按分组查询详情。'
    body=to_wire_dict({**build_text_message_request(to_user_id=user_id,text=plain,context_token=context_token,client_id=generate_client_id()),'base_info':build_base_info()})
    encoded=encode_json_body(body)
    response=await http.post(urljoin(account.base_url.rstrip('/')+'/','ilink/bot/sendmessage'),
        headers=build_json_headers(body=encoded,token=account.bot_token,route_tag=account.route_tag),content=encoded.encode())
    response.raise_for_status();payload=response.json()
    if not isinstance(payload,dict) or payload.get('errcode') not in (None,0) or payload.get('ret') not in (None,0):
        raise RuntimeError('reply rejected')

async def run(args):
    import httpx,qrcode
    from wechat_clawbot_sdk import AsyncWeChatBotClient,FileStateStore
    from wechat_clawbot_sdk.messaging.inbound import normalize_inbound_message
    from wechat_clawbot_sdk.api.headers import build_base_info,build_json_headers,encode_json_body
    from wechat_clawbot_sdk.api.encoding import to_wire_dict
    logging.disable(logging.CRITICAL);os.umask(0o077)
    ROOT.mkdir(parents=True,exist_ok=True,mode=0o700);RUNTIME.mkdir(parents=True,exist_ok=True,mode=0o700)
    lock=open(RUNTIME/'wechat-worker.lock','w')
    try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BlockingIOError:raise WorkerAlreadyRunning('worker already running')
    if not (RUNTIME/'command.sock').exists():raise RuntimeError('native app not running')
    class AtomicState(FileStateStore):
        @staticmethod
        def _write_json_sync(path,payload):atomic_json(path,payload)
    active=ROOT/'active-sdk.json'
    if args.login_again or not active.exists():
        atomic_json(active,{'directory':'sdk-'+str(uuid.uuid4())})
    directory=json.loads(active.read_text())['directory']
    if not directory.startswith('sdk-') or '/' in directory:raise RuntimeError('invalid SDK directory')
    sdk=ROOT/directory;store=AtomicState(sdk)
    bot=AsyncWeChatBotClient.create(state_store=store,debug=False)
    inbox=DurableInbox(ROOT/'inbox.sqlite')
    inbox.db.execute('CREATE TABLE IF NOT EXISTS replies (operation_id TEXT PRIMARY KEY,state TEXT NOT NULL)')
    async def qr_ready(qr):
        qr_temp=ROOT/'login-stage.png';qrcode.make(qr.qrcode_image_content).save(qr_temp);os.replace(qr_temp,ROOT/'login.png')
        status('waiting_for_scan',qr_updated_at=int(time.time()))
    try:
        accounts=[p for p in (sdk/'accounts').glob('*.json') if not p.name.endswith(('.sync.json','.context-tokens.json'))]
        if len(accounts)>1:raise RuntimeError('ambiguous accounts')
        if accounts:account=await store.load_account_session(accounts[0].stem)
        else:
            qr=await bot.start_login();await qr_ready(qr)
            account=await bot.wait_for_login(qr.qrcode,timeout_seconds=300,on_qrcode_refresh=qr_ready)
        url=urlsplit(account.base_url)
        if url.scheme!='https' or not url.hostname or not (url.hostname=='weixin.qq.com' or url.hostname.endswith('.weixin.qq.com')):
            raise RuntimeError('unexpected bot API host')
        # Raw message payloads stay private, not in status/report. All durable records are owner-only.
        received=0;status('starting',processed=received)
        async with httpx.AsyncClient(timeout=httpx.Timeout(45,connect=10),follow_redirects=False) as http:
            while True:
                # Drain old pending work first. A busy native service never causes an acknowledgement.
                for op,raw in inbox.pending(account.account_id):
                    message=normalize_inbound_message(account.account_id,raw)
                    if not message.text or not message.context_token:
                        inbox.acknowledge(op);continue
                    conversation=hashlib.sha256((account.account_id+'|'+message.user_id).encode()).hexdigest()
                    try:result=await asyncio.to_thread(request_service,message.text,op,conversation)
                    except (OSError,TimeoutError,RuntimeError):
                        status('waiting_for_app',processed=received);await asyncio.sleep(2);break
                    if result.get('status') in {'busy','uncertain'}:
                        status('waiting_for_app',processed=received);await asyncio.sleep(2);break
                    # A durable preclaim prevents blind resends after an uncertain external send.
                    claimed=inbox.db.execute('INSERT OR IGNORE INTO replies VALUES (?,?)',(op,'uncertain')).rowcount
                    if claimed:
                        try:
                            await send_plain_reply(http,account,message.user_id,message.context_token,result.get('message','处理失败，请查看菜单栏。'))
                            inbox.db.execute('UPDATE replies SET state=? WHERE operation_id=?',('accepted',op))
                        except Exception:
                            status('reply_uncertain',processed=received);return 2
                    inbox.acknowledge(op);received+=1;status('connected',processed=received)
                if inbox.pending(account.account_id):continue
                body=to_wire_dict({'get_updates_buf':inbox.cursor(account.account_id),'base_info':build_base_info()})
                encoded=encode_json_body(body)
                try:
                    response=await http.post(urljoin(account.base_url.rstrip('/')+'/','ilink/bot/getupdates'),
                        headers=build_json_headers(body=encoded,token=account.bot_token,route_tag=account.route_tag),content=encoded.encode())
                    response.raise_for_status();payload=response.json()
                except httpx.TimeoutException:continue
                except (httpx.HTTPError,ValueError):
                    status('network_error',processed=received);await asyncio.sleep(5);continue
                code,messages,cursor=decode_poll_payload(payload,inbox.cursor(account.account_id))
                if code==-14:status('session_expired',processed=received);return 2
                if code not in (0,None):status('protocol_error',processed=received);return 2
                status('connected',processed=received,poll_verified=True,response_fields=sorted(payload.keys()),ret_present='ret' in payload)
                inbox.commit_batch(account.account_id,messages,cursor)
    finally:
        inbox.close();await bot.close()

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--old-owner-stopped',action='store_true');p.add_argument('--login-again',action='store_true');p.add_argument('--parent-pid',type=int);a=p.parse_args()
    if not a.old_owner_stopped:p.error('old sender must be confirmed stopped; no automatic handoff')
    try:sys.exit(asyncio.run(supervise(a)) or 0)
    except WorkerAlreadyRunning:sys.exit(3) # Never overwrite the active owner's status.
    except KeyboardInterrupt:status('stopped')
    except Exception as exc:report_failure(exc);status('blocked',error_type=type(exc).__name__);sys.exit(2)
