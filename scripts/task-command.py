#!/usr/bin/env python3
"""Send a local command to the running native app. Does not poll or send WeChat."""
import argparse,hashlib,json,socket,uuid
from pathlib import Path

def request(text,request_id=None,conversation='local-cli'):
    root=Path.home()/'.tasksecretary/runtime'
    payload={'token':json.loads((root/'command-token.json').read_text()),
        'requestId':request_id or str(uuid.uuid4()),'source':'wechat:'+hashlib.sha256(conversation.encode()).hexdigest(),'text':text}
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(75);s.connect(str(root/'command.sock'));s.sendall(json.dumps(payload,ensure_ascii=False).encode()+b'\n')
        with s.makefile('rb') as f:response=json.loads(f.readline(65537))
    return response
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--text',required=True);p.add_argument('--request-id');p.add_argument('--conversation',default='local-cli');a=p.parse_args()
    print(json.dumps(request(a.text,a.request_id,a.conversation),ensure_ascii=False))
