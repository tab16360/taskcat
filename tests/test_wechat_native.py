"""Built-in WeChat bridge: protocol rules, durable inbox, and the real bridge loop against a
local fake iLink server. No WeChat account, network or personal data is involved."""
import json,os,subprocess,threading,uuid
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse,parse_qs
import pytest
ROOT=Path(__file__).resolve().parents[1]
SRC=ROOT/'apps/macos/Sources'

PROBE=r'''import Foundation
import AppKit
@main struct Probe {
 @MainActor static func main() async throws {
  let a=CommandLine.arguments,mode=a[1]
  func out(_ v:Any){print(String(data:try! JSONSerialization.data(withJSONObject:v,options:[.sortedKeys]),encoding:.utf8)!)}
  switch mode {
  case "rules":
   let h=ILinkProtocol.headers(token:" tok ",routeTag:"rt",appVersion:"1.2.3",uin:4021)
   let plain=ILinkProtocol.headers(token:nil,routeTag:nil,appVersion:"1.0.0",uin:7)
   let big=try ILinkProtocol.losslessJSON(Data(#"{"message_id": 18446744073709551615,"n":5}"#.utf8)) as! [String:Any]
   func inbound(_ j:String)->String {ILinkProtocol.inbound(try! JSONSerialization.jsonObject(with:Data(j.utf8)) as! [String:Any]).map{$0.userID+"|"+$0.text+"|"+$0.contextToken} ?? "nil"}
   func poll(_ j:String,_ prev:String)->String {
    do {let (r,m)=try ILinkProtocol.interpretPoll(try JSONSerialization.jsonObject(with:Data(j.utf8)) as! [String:Any],previousCursor:prev);return "\(r)|\(m.count)"} catch {return "error"}
   }
   func login(_ j:String)->String {"\(ILinkProtocol.loginStatus(try! JSONSerialization.jsonObject(with:Data(j.utf8)) as! [String:Any],currentBase:URL(string:"https://ilinkai.weixin.qq.com")!))"}
   out(["headers":h,"plain":plain,"version":ILinkProtocol.clientVersion("1.0.0"),"big":big["message_id"] as! String,
        "text":inbound(#"{"message_type":1,"from_user_id":"u1","context_token":"c1","item_list":[{"type":1,"text_item":{"text":"明天十点开会"}}]}"#),
        "voice":inbound(#"{"from_user_id":"u1","context_token":"c1","item_list":[{"type":3,"voice_item":{"text":"买猫粮"}}]}"#),
        "bot":inbound(#"{"message_type":2,"from_user_id":"u1","context_token":"c1","item_list":[{"type":1,"text_item":{"text":"x"}}]}"#),
        "image":inbound(#"{"from_user_id":"u1","context_token":"c1","item_list":[{"type":2}]}"#),
        "nocontext":inbound(#"{"from_user_id":"u1","item_list":[{"type":1,"text_item":{"text":"x"}}]}"#),
        "pollOK":poll(#"{"get_updates_buf":"c2","msgs":[{"a":1}]}"#,"c1"),"pollEmptyCursor":poll(#"{"ret":0,"get_updates_buf":""}"#,"c1"),
        "pollStale":poll(#"{"errcode":-14}"#,"c1"),"pollRejected":poll(#"{"ret":-3}"#,"c1"),"pollNoCursor":poll(#"{"ret":0}"#,"c1"),
        "loginConfirmed":login(#"{"status":"confirmed","bot_token":"t","ilink_bot_id":"b@im.bot","baseurl":"https://x.weixin.qq.com","ilink_user_id":"u"}"#),
        "loginNoBot":login(#"{"status":"confirmed","bot_token":"t"}"#),"loginRedirect":login(#"{"status":"scaned_but_redirect","redirect_host":"sz.weixin.qq.com"}"#),
        "loginVerify":login(#"{"status":"need_verifycode"}"#),
        "trusted":[ILinkProtocol.trustedHost(URL(string:"https://ilinkai.weixin.qq.com/x")!),ILinkProtocol.trustedHost(URL(string:"https://weixin.qq.com.evil.com")!),ILinkProtocol.trustedHost(URL(string:"http://ilinkai.weixin.qq.com")!)],
        "op":ILinkProtocol.operationID(account:"acc@im.bot",sender:"user@im.wechat",messageID:"18446744073709551615")])
  case "inbox":
   let path=URL(fileURLWithPath:a[2]);var inbox:WeChatInbox?=try WeChatInbox(path:path)
   let m1:[String:Any]=["message_id":"9007199254740993","from_user_id":"u1","context_token":"c"],m2:[String:Any]=["message_id":"2","from_user_id":"u2"]
   let ops=try inbox!.commitBatch("acc",messages:[m1,m2],cursor:"k1")
   _=try inbox!.commitBatch("acc",messages:[m1],cursor:"k2")          // duplicate delivery
   var invalid="ok";do{_=try inbox!.commitBatch("acc",messages:[["from_user_id":"u3"]],cursor:"k3")}catch{invalid="rejected"}
   try inbox!.acknowledge(ops[0])
   let firstClaim=try inbox!.claimReply(ops[1]),secondClaim=try inbox!.claimReply(ops[1])
   inbox=nil;let reopened=try WeChatInbox(path:path)                   // survives reopening
   out(["cursor":try reopened.cursor("acc"),"pending":try reopened.pending("acc").map(\.operationID),"ops":ops,"invalid":invalid,
        "claims":[firstClaim,secondClaim],"reply":try reopened.replyState(ops[1]) ?? "nil","bigID":ILinkProtocol.string(try reopened.pending("acc").first?.message["message_id"]) ?? "nil",
        "other":try reopened.cursor("other")])
  case "bridge":
   let root=URL(fileURLWithPath:a[2]),base=URL(string:a[3])!
   var states:[String]=[],calls:[String]=[]
   var options=WeChatBridge.Options(root:root,lockFile:root.appendingPathComponent("lock"),loginBase:base,appVersion:"1.0.0")
   options.trustedHost={_ in true};options.pollTimeout=2;options.retryDelay=200_000_000
   let config=URLSessionConfiguration.ephemeral;config.connectionProxyDictionary=[:];options.session=URLSession(configuration:config)
   var bridge:WeChatBridge!
   bridge=WeChatBridge(options:options,handler:{text,source,id in calls.append(text+"|"+source.prefix(7)+"|"+id);return ServiceResult(ok:true,status:"applied",message:"已记下："+text,requestId:id)},
                       sink:{state,_ in states.append(state);if state=="need_verifycode"{bridge.submitVerifyCode("468")}})
   bridge.start()
   let until=a[4],deadline=Date().addingTimeInterval(20)
   while Date()<deadline {
    try await Task.sleep(nanoseconds:100_000_000)
    if until=="processed",bridge.processed>=Int(a[5])! {break}
    if until=="state",states.contains(a[5]) {break}
   }
   bridge.stop();await bridge.wait()
   let account=(try? JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("native-account.json")))) as? [String:Any]
   out(["states":states,"calls":calls,"account":(account?["accountID"] as? String) ?? "none","baseURL":(account?["baseURL"] as? String) ?? "none"])
  default:fatalError()
  }
 }
}
'''

@pytest.fixture(scope='session')
def probe(tmp_path_factory):
    folder=tmp_path_factory.mktemp('wechat-native')
    main=folder/'Main.swift';main.write_text(PROBE)
    binary=folder/'probe'
    files=[ROOT/'poc/metadata-journal/OperationJournal.swift',SRC/'Domain.swift',SRC/'WeChatProtocol.swift',SRC/'WeChatInbox.swift',SRC/'WeChatBridge.swift',main]
    r=subprocess.run(['swiftc','-parse-as-library','-swift-version','5',*map(str,files),'-o',str(binary)],capture_output=True,text=True,timeout=180)
    assert r.returncode==0,r.stderr
    return binary

def run(binary,*args,timeout=40):
    r=subprocess.run([str(binary),*map(str,args)],capture_output=True,text=True,timeout=timeout)
    assert r.returncode==0,r.stderr
    return json.loads(r.stdout.strip().splitlines()[-1])

def test_protocol_rules(probe):
    r=run(probe,'rules')
    assert r['headers']['Authorization']=='Bearer tok' and r['headers']['AuthorizationType']=='ilink_bot_token'
    assert r['headers']['SKRouteTag']=='rt' and r['headers']['iLink-App-Id']=='bot' and r['headers']['iLink-App-ClientVersion']==str(1<<16|2<<8|3)
    assert r['headers']['X-WECHAT-UIN']=='NDAyMQ=='                       # base64 of the decimal "4021"
    assert 'Authorization' not in r['plain'] and 'SKRouteTag' not in r['plain'] and r['version']==65536
    assert r['big']=='18446744073709551615'                             # uint64 kept exactly
    assert r['text']=='u1|明天十点开会|c1' and r['voice']=='u1|买猫粮|c1'
    assert r['bot']=='nil' and r['image']=='nil' and r['nocontext']=='nil'
    assert r['pollOK']=='batch(messages: 1, cursor: "c2")|1' and r['pollEmptyCursor']=='batch(messages: 0, cursor: "c1")|0'
    assert r['pollStale']=='sessionExpired|0' and r['pollRejected']=='rejected(code: -3)|0' and r['pollNoCursor']=='error'
    assert 'confirmed' in r['loginConfirmed'] and 'b@im.bot' in r['loginConfirmed'] and 'https://x.weixin.qq.com' in r['loginConfirmed']
    assert r['loginNoBot'].startswith('failed') and r['loginRedirect']=='redirect(host: "sz.weixin.qq.com")' and r['loginVerify']=='needVerifyCode'
    assert r['trusted']==[True,False,False]
    # Same operation ID the old Python bridge produced, so no message is handled twice across the switch.
    identity=json.dumps(['acc@im.bot','user@im.wechat','18446744073709551615'],ensure_ascii=False,separators=(',',':'))
    assert r['op']==str(uuid.uuid5(uuid.NAMESPACE_URL,'tasksecretary:wechat:'+identity))

def test_inbox_is_atomic_deduplicated_and_durable(probe,tmp_path):
    r=run(probe,'inbox',tmp_path/'inbox.sqlite')
    assert r['cursor']=='k2' and r['invalid']=='rejected'               # invalid batch did not move the cursor
    assert r['pending']==[r['ops'][1]] and r['claims']==[True,False] and r['reply']=='uncertain'
    assert r['other']=='' and r['bigID']=='2'

class FakeILink:
    """Minimal iLink server: scripted login, one queued message, recorded replies."""
    def __init__(self,messages=(),reply_ret=0,login=None):
        self.queue=list(messages);self.reply_ret=reply_ret;self.login=list(login or []);self.sent=[];self.headers=[];self.cursor='c0';self.verify=[]
        fake=self
        class H(BaseHTTPRequestHandler):
            def log_message(self,*a):pass
            def reply(self,obj):
                body=json.dumps(obj).encode();self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            def do_GET(self):
                q=parse_qs(urlparse(self.path).query)
                if 'verify_code' in q:fake.verify.append(q['verify_code'][0])
                self.reply({'status':fake.login.pop(0)} if fake.login and isinstance(fake.login[0],str) else (fake.login.pop(0) if fake.login else {'status':'wait'}))
            def do_POST(self):
                body=json.loads(self.rfile.read(int(self.headers['Content-Length'])) or b'{}')
                fake.headers.append(dict(self.headers))
                path=urlparse(self.path).path
                if path.endswith('get_bot_qrcode'):return self.reply({'qrcode':'q1','qrcode_img_content':'https://liteapp.weixin.qq.com/q/demo'})
                if path.endswith('getupdates'):
                    if fake.queue:
                        fake.cursor='c%d'%(len(fake.sent)+1);msg=fake.queue.pop(0)
                        return self.reply({'ret':0,'msgs':[msg],'get_updates_buf':fake.cursor})
                    import time;time.sleep(.3);return self.reply({'ret':0,'msgs':[],'get_updates_buf':fake.cursor})
                if path.endswith('sendmessage'):
                    fake.sent.append(body);return self.reply({'ret':fake.reply_ret})
                self.reply({'ret':0})
        self.server=ThreadingHTTPServer(('127.0.0.1',0),H);self.url='http://127.0.0.1:%d'%self.server.server_port
        threading.Thread(target=self.server.serve_forever,daemon=True).start()
    def close(self):self.server.shutdown()

def message(text,mid='7001'):
    return {'message_id':int(mid),'message_type':1,'from_user_id':'user@im.wechat','context_token':'ctx-1','item_list':[{'type':1,'text_item':{'text':text}}]}

def save_account(root,url):
    root.mkdir(parents=True,exist_ok=True)
    (root/'native-account.json').write_text(json.dumps({'accountID':'acc@im.bot','botID':'acc@im.bot','baseURL':url,'botToken':'secret-token','userID':'owner'}))

def test_message_is_handled_once_and_answered_in_context(probe,tmp_path):
    fake=FakeILink(messages=[message('明天下午三点交周报')])
    try:
        root=tmp_path/'wechat';save_account(root,fake.url)
        r=run(probe,'bridge',root,fake.url,'processed',1)
        assert len(r['calls'])==1 and r['calls'][0].startswith('明天下午三点交周报|wechat:|')
        assert len(fake.sent)==1
        msg=fake.sent[0]['msg']
        assert msg['to_user_id']=='user@im.wechat' and msg['context_token']=='ctx-1' and msg['message_type']==2
        assert msg['item_list'][0]['text_item']['text']=='已记下：明天下午三点交周报'
        auth=[h for h in fake.headers if h.get('Authorization')]
        assert auth and all(h['Authorization']=='Bearer secret-token' and h['AuthorizationType']=='ilink_bot_token' for h in auth)
        assert 'connected' in r['states']
        # Restart: the cursor and inbox carry over, nothing is handled or answered again.
        r2=run(probe,'bridge',root,fake.url,'state','connected')
        assert r2['calls']==[] and len(fake.sent)==1
    finally:fake.close()

def test_failed_reply_is_never_sent_twice(probe,tmp_path):
    fake=FakeILink(messages=[message('任务1标记完成','7002')],reply_ret=-1)
    try:
        root=tmp_path/'wechat';save_account(root,fake.url)
        r=run(probe,'bridge',root,fake.url,'state','reply_uncertain')
        assert 'reply_uncertain' in r['states'] and len(fake.sent)==1
        fake.reply_ret=0
        r2=run(probe,'bridge',root,fake.url,'state','connected')
        assert len(fake.sent)==1                                          # uncertain reply not repeated
    finally:fake.close()

def test_scan_login_with_verify_code_saves_the_session(probe,tmp_path):
    fake=FakeILink(login=['wait','scaned','need_verifycode',{'status':'confirmed','bot_token':'new-token','ilink_bot_id':'bot9@im.bot','baseurl':'','ilink_user_id':'me'}])
    try:
        root=tmp_path/'wechat'
        r=run(probe,'bridge',root,fake.url,'state','connected')
        assert r['states'][:2]==['starting','waiting_for_scan'] and 'scanned' in r['states'] and 'need_verifycode' in r['states']
        assert fake.verify==['468'] and r['account']=='bot9@im.bot' and r['baseURL']==fake.url
        assert oct((root/'native-account.json').stat().st_mode)[-3:]=='600'
    finally:fake.close()

def test_session_from_the_old_python_bridge_is_imported(probe,tmp_path):
    fake=FakeILink()
    try:
        root=tmp_path/'wechat';sdk=root/'sdk-1234'/'accounts';sdk.mkdir(parents=True)
        (root/'active-sdk.json').write_text(json.dumps({'directory':'sdk-1234'}))
        (sdk/'old@im.bot.json').write_text(json.dumps({'account_id':'old@im.bot','bot_id':'old@im.bot','base_url':fake.url,'bot_token':'legacy','route_tag':None,'user_id':'me'}))
        (sdk/'old@im.bot.sync.json').write_text('{}')
        r=run(probe,'bridge',root,fake.url,'state','connected')
        assert r['account']=='old@im.bot' and 'waiting_for_scan' not in r['states']
        assert any(h.get('Authorization')=='Bearer legacy' for h in fake.headers)
    finally:fake.close()
