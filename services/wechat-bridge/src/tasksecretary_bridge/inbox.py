"""Durable batch barrier: messages and polling cursor commit in one SQLite transaction.
Transport must commit_batch BEFORE dispatch; Worker must acknowledge only after its
idempotent domain transaction. This module alone does not replace SDK polling.
"""
import hashlib,json,os,sqlite3,uuid
from pathlib import Path

class DurableInbox:
    def __init__(self,path):
        path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        fd=os.open(path,os.O_CREAT|os.O_WRONLY,0o600);os.close(fd);os.chmod(path,0o600)
        self.db=sqlite3.connect(path,isolation_level=None)
        self.db.execute('PRAGMA journal_mode=WAL')
        self.db.execute('PRAGMA synchronous=FULL')
        self.db.execute('CREATE TABLE IF NOT EXISTS cursors (account TEXT PRIMARY KEY, value TEXT NOT NULL)')
        self.db.execute('CREATE TABLE IF NOT EXISTS inbox (operation_id TEXT PRIMARY KEY, account TEXT NOT NULL, payload TEXT NOT NULL, done INTEGER NOT NULL DEFAULT 0)')
    @staticmethod
    def account_key(account):return hashlib.sha256(account.encode()).hexdigest()
    def cursor(self,account):
        row=self.db.execute('SELECT value FROM cursors WHERE account=?',(self.account_key(account),)).fetchone()
        return row[0] if row else ''
    def commit_batch(self,account,messages,next_cursor):
        if not isinstance(next_cursor,str):raise ValueError('cursor must be a string')
        prepared=[];account_key=self.account_key(account)
        for message in messages:
            if not isinstance(message,dict) or message.get('message_id') is None or not message.get('from_user_id'):
                raise ValueError('stable platform message ID and sender required; cursor not advanced')
            identity=json.dumps([account,str(message['from_user_id']),str(message['message_id'])],ensure_ascii=False,separators=(',',':'))
            op=str(uuid.uuid5(uuid.NAMESPACE_URL,'tasksecretary:wechat:'+identity))
            prepared.append((op,account_key,json.dumps(message,ensure_ascii=False,separators=(',',':'))))
        try:
            self.db.execute('BEGIN IMMEDIATE')
            self.db.executemany('INSERT OR IGNORE INTO inbox(operation_id,account,payload) VALUES (?,?,?)',prepared)
            self.db.execute('INSERT INTO cursors VALUES (?,?) ON CONFLICT(account) DO UPDATE SET value=excluded.value',(account_key,next_cursor))
            self.db.commit()
        except BaseException:
            self.db.rollback();raise
        return [row[0] for row in prepared]
    def pending(self,account):
        rows=self.db.execute('SELECT operation_id,payload FROM inbox WHERE account=? AND done=0 ORDER BY rowid',(self.account_key(account),)).fetchall()
        return [(op,json.loads(payload)) for op,payload in rows]
    def acknowledge(self,operation_id):
        if self.db.execute('UPDATE inbox SET done=1 WHERE operation_id=?',(operation_id,)).rowcount!=1:
            raise ValueError('unknown operation ID')
    def close(self):self.db.close()
