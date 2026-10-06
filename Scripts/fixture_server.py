#!/usr/bin/env python3
"""Local OPDS + KOReader protocol smoke server; no real account/data required.
Use only for development. Credentials: demo / demo. Run from any directory.
"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit, parse_qs
import base64, hashlib, json, time, argparse, threading
ROOT=Path(__file__).resolve().parents[1]
PROGRESS={}; LOCK=threading.Lock()
class Handler(BaseHTTPRequestHandler):
    def send(self, status, data, mime='application/json'):
        if isinstance(data,dict): data=json.dumps(data).encode()
        self.send_response(status); self.send_header('Content-Type',mime); self.send_header('Content-Length',str(len(data))); self.end_headers(); self.wfile.write(data)
    def authenticated(self, sync=False):
        if sync:
            ok=self.headers.get('X-Auth-User')=='demo' and self.headers.get('X-Auth-Key')==hashlib.md5(b'demo').hexdigest()
        else: ok=self.headers.get('Authorization')=='Basic '+base64.b64encode(b'demo:demo').decode()
        if not ok:
            self.send(401,{'error':'unauthorized'})
        return ok
    def do_GET(self):
        parsed=urlsplit(self.path); path=parsed.path
        if path.startswith('/syncs/') or path=='/users/auth':
            if not self.authenticated(True): return
            with LOCK: result=PROGRESS.get(path.rsplit('/',1)[-1],{}).copy()
            return self.send(200,{} if path=='/users/auth' else result)
        if not self.authenticated(): return
        if path=='/books/sample.epub':
            data=(ROOT/'Tests/Fixtures/sample.epub').read_bytes(); return self.send(200,data,'application/epub+zip')
        if path.startswith('/opds'):
            page=parse_qs(parsed.query).get('page',['1'])[0]
            next_link='<link rel="next" href="/opds?page=2"/>' if page=='1' else ''
            title='测试图书' if page=='1' else '第二页图书'
            xml=f'''<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>本地测试书库</title><id>demo</id><updated>2026-10-06T00:00:00Z</updated><link rel="search" href="/opds/search?q={{searchTerms}}" type="application/atom+xml"/>{next_link}<entry><id>sample-{page}</id><title>{title}</title><author><name>Simple Reader</name></author><summary>验证下载、去重和同步的中英文 EPUB。</summary><link rel="http://opds-spec.org/acquisition" href="/books/sample.epub" type="application/epub+zip"/></entry></feed>'''
            return self.send(200,xml.encode(),'application/atom+xml')
        self.send(404,{'error':'not found'})
    def do_PUT(self):
        if self.path!='/syncs/progress': return self.send(404,{})
        if not self.authenticated(True): return
        try:
            data=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            data['timestamp']=time.time()
            with LOCK: PROGRESS[data['document']]=data
            self.send(200,{'status':'ok'})
        except Exception: self.send(400,{'error':'invalid payload'})
if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--port',type=int,default=8765);args=parser.parse_args()
    print(f'OPDS http://127.0.0.1:{args.port}/opds; KOReader http://127.0.0.1:{args.port}; demo/demo',flush=True)
    ThreadingHTTPServer(('127.0.0.1',args.port),Handler).serve_forever()
