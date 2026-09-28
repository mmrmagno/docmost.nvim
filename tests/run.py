#!/usr/bin/env python3
"""Loopback-only integration fixture; never connects to a Docmost deployment."""
import copy
import json
import os
from pathlib import Path
import secrets
import ssl
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ROOT = Path(__file__).resolve().parents[1]
TOKEN, PASSWORD = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
MARKDOWN = '# Notes\n\nGrüezi 世界 **bold** and _italic_ and ~~strike~~.\n\n- one\n- two\n\n```lua\nprint("hi")\n```'
DOCUMENT = {'type': 'doc', 'content': [
    {'type': 'heading', 'attrs': {'level': 1, 'id': None, 'textAlign': None, 'indent': 0}, 'content': [{'type': 'text', 'text': 'Notes'}]},
    {'type': 'paragraph', 'content': [{'type': 'text', 'text': 'Grüezi 世界 '}, {'type': 'text', 'text': 'bold', 'marks': [{'type': 'bold'}]},
      {'type': 'text', 'text': ' and '}, {'type': 'text', 'text': 'italic', 'marks': [{'type': 'italic'}]},
      {'type': 'text', 'text': ' and '}, {'type': 'text', 'text': 'strike', 'marks': [{'type': 'strike'}]}, {'type': 'text', 'text': '.'}]},
    {'type': 'bulletList', 'content': [{'type': 'listItem', 'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': v}]}]} for v in ['one', 'two']]},
    {'type': 'codeBlock', 'attrs': {'language': 'lua'}, 'content': [{'type': 'text', 'text': 'print("hi")'}]},
]}
state = {}


def reset():
    state.clear()
    state.update(mode='normal', writes=[], reads=0, trace=[], generation=0, pending=None,
                 markdown=MARKDOWN, document=copy.deepcopy(DOCUMENT), title='Title stays separate', icon=None)


reset()


def walk(node):
    yield node
    for child in node.get('content', []):
        yield from walk(child)


def render(node):
    """Small independent mock serializer, not the production Markdown parser."""
    kind = node['type']
    children = node.get('content', [])
    attrs = node.get('attrs') or {}
    if kind == 'text':
        text = node['text']
        for mark in node.get('marks', []):
            delimiter = {'bold': '**', 'italic': '_', 'strike': '~~', 'code': '`'}.get(mark['type'], '')
            text = delimiter + text + delimiter
        return text
    if kind == 'paragraph':
        return ''.join(render(child) for child in children)
    if kind == 'heading':
        return '#' * (attrs or {}).get('level', 1) + ' ' + ''.join(render(child) for child in children)
    if kind == 'codeBlock':
        return '```' + (attrs.get('language') or '') + '\n' + ''.join(render(c) for c in children) + '\n```'
    if kind in ['bulletList', 'orderedList']:
        return '\n'.join(('- ' if kind == 'bulletList' else f"{i + attrs.get('start', 1)}. ") + render(child) for i, child in enumerate(children))
    if kind == 'blockquote':
        return '\n'.join('> ' + line for line in '\n\n'.join(render(c) for c in children).splitlines())
    if kind == 'horizontalRule':
        return '---'
    return '\n\n'.join(render(child) for child in children).strip('\n')


class Handler(BaseHTTPRequestHandler):
    def handle(self):
        try:
            super().handle()
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when cancellation/TLS validation closes the socket.

    def log_message(self, *_):
        pass

    def send(self, data, code=200, content_type='application/json', cookie=False):
        raw = json.dumps(data).encode() if content_type == 'application/json' else data.encode()
        self.send_response(code)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(raw)))
        if cookie:
            self.send_header('Set-Cookie', f'authToken={TOKEN}; HttpOnly; Path=/; SameSite=Lax')
        if code == 302:
            self.send_header('Location', 'https://invalid.example/collect')
        self.end_headers()
        try:
            self.wfile.write(raw)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get('Content-Length', 0))))
        if not isinstance(body, dict):
            return self.send({'message': 'Request must be a JSON object'}, 400)
        route = self.path.removeprefix('/api')
        if route == '/control':
            if body.get('reset'):
                reset()
            state.update({k: v for k, v in body.items() if k != 'reset'})
            if body.get('reset') and body.get('mode') == 'anchored':
                for i, node in enumerate(walk(state['document'])):
                    if node['type'] in ['paragraph', 'heading']:
                        node.setdefault('attrs', {}).update(id=f'keep-{i}', textAlign='left')
            return self.send({'data': {}})
        if route == '/stats':
            return self.send({'data': {k: state[k] for k in ['writes', 'reads', 'trace', 'markdown']}})
        if route == '/auth/login':
            if body.get('password') != PASSWORD:
                return self.send({'message': body.get('password')}, 401)
            return self.send({'data': {'user': {'id': 'user-1'}}, 'success': True}, cookie=True)
        mode = state['mode']
        if mode == 'expired' or self.headers.get('Cookie') != f'authToken={TOKEN}':
            return self.send({'message': 'denied'}, 401)
        if mode == 'html':
            return self.send('<html>login</html>', content_type='text/html')
        if mode == 'malformed':
            return self.send('{broken', content_type='application/json; charset=utf-8')
        if mode == 'oversize':
            return self.send('x' * 50000, content_type='text/html')
        if mode == 'redirect':
            return self.send({}, 302)
        if mode == 'rate':
            return self.send({'message': TOKEN}, 429)
        if mode == 'slow':
            time.sleep(.3)
        if mode == 'application':
            return self.send({'success': False, 'message': TOKEN})
        if route == '/users/me':
            return self.send({'data': {'user': {'id': 'user-1', 'name': 'Test user'}, 'workspace': {'id': 'workspace-1'}}})
        if route in ['/spaces', '/pages/sidebar-pages', '/search']:
            state['trace'].append([route, body])
            if route == '/search':
                if mode == 'slowsearch':
                    time.sleep(.3)
                items = [{'id': f"search-{body.get('offset', 0)}", 'title': 'Result', 'space': {'id': 'space-1', 'name': 'Engineering'}}] \
                    if body.get('offset', 0) < 4 and body.get('query') != 'nothing' else []
                return self.send({'data': {'items': items}})
            cursor = body.get('cursor')
            name = 'Child' if body.get('pageId') else 'Root'
            items = [{'id': f'{name.lower()}-{2 if cursor else 1}', 'title': name, 'name': name,
                      'slug': name.lower(), 'hasChildren': not body.get('pageId')}]
            return self.send({'data': {'items': items, 'meta': {'nextCursor': None if cursor else 'next', 'hasNextPage': not bool(cursor)}}})
        if route == '/pages/info':
            state['reads'] += 1
            pending = state['pending']
            if pending and time.monotonic() >= pending[0]:
                state['markdown'], state['document'] = pending[1:]
                state['generation'] += 1
                state['pending'] = None
            document = state['document']
            if mode == 'rich':
                document = {'type': 'doc', 'content': [{'type': 'attachment', 'attrs': {'attachmentId': 'keep-me'}}]}
            if mode == 'changing':
                state['generation'] += 1
            if mode == 'wrongempty':
                document = copy.deepcopy(DOCUMENT)
            page = {'id': 'page-1', 'title': state['title'], 'icon': state['icon'], 'updatedAt': str(state['generation']), 'spaceId': 'space-1',
                    'permissions': {'canEdit': mode != 'readonly'},
                    'content': document if body['format'] == 'json' else state['markdown']}
            if mode == 'nullbody':
                page['content'] = None
            if mode == 'missingbody':
                del page['content']
            return self.send({'data': page, 'success': True, 'status': 200})
        if route == '/pages/update':
            if mode == 'forbidden':
                return self.send({'message': TOKEN}, 403)
            state['writes'].append(body)
            if 'content' not in body:
                if mode == 'renamefail':
                    return self.send({'message': 'slow down'}, 429)
                if mode != 'ignored':
                    state['title'] = body.get('title', state['title'])
                    state['icon'] = body.get('icon', state['icon']) or None
                    state['generation'] += 1
                return self.send({'data': {'id': 'page-1'}})
            if mode == 'ignored':
                return self.send({'data': {'id': 'page-1'}})
            markdown = body['content'] if body['format'] == 'markdown' else render(body['content'])
            if mode == 'canonicalize':
                markdown = markdown.replace('**new**', '__new__')
            # Transport fixtures intentionally are not a Markdown parser.
            document = body['content'] if body['format'] == 'json' else copy.deepcopy(DOCUMENT)
            if mode == 'newanchor':
                if body['format'] == 'markdown':
                    document = {'type': 'doc', 'content': [{'type': 'paragraph', 'content': [{'type': 'text', 'text': markdown}]}]}
                document['content'][0].setdefault('attrs', {})['id'] = 'generated-id'
            if mode == 'dropids':
                document = copy.deepcopy(document)
                for node in walk(document):
                    node.get('attrs', {}).pop('id', None)
            delay = .14 if mode in ['delayed', 'ambiguous'] else 0
            state['pending'] = (time.monotonic() + delay, markdown, document)
            if mode == 'ambiguous':
                time.sleep(.3)
            return self.send({'data': {'id': 'page-1'}})
        return self.send({}, 404)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    with tempfile.TemporaryDirectory(prefix='docmost-tests-') as directory:
        cert, key = f'{directory}/cert.pem', f'{directory}/key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                        '-keyout', key, '-out', cert, '-subj', '/CN=127.0.0.1', '-addext', 'subjectAltName=IP:127.0.0.1'],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        tls_server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
        threading.Thread(target=tls_server.serve_forever, daemon=True).start()
        env = dict(os.environ, DOCMOST_TEST_URL=f'http://127.0.0.1:{server.server_port}', DOCMOST_TEST_DIR=directory,
                   DOCMOST_TEST_TOKEN=TOKEN, DOCMOST_TEST_PASSWORD=PASSWORD, DOCMOST_TEST_CERT=cert,
                   DOCMOST_TEST_TLS_URL=f'https://127.0.0.1:{tls_server.server_port}',
                   NO_PROXY='127.0.0.1', no_proxy='127.0.0.1')
        for kind in ['CONFIG', 'DATA', 'STATE', 'CACHE']:
            env[f'XDG_{kind}_HOME'] = f'{directory}/xdg-{kind.lower()}'
        for unit in ['tests/dfm.lua', 'tests/layout.lua']:
            unit_test = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '--cmd', f'set rtp+={ROOT}',
                                        '-l', str(ROOT / unit)], env=env, cwd=ROOT, timeout=30)
            if unit_test.returncode:
                raise SystemExit(unit_test.returncode)
        result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '--cmd', f'set rtp+={ROOT}',
                                 '-l', str(ROOT / 'tests/integration.lua')], env=env, cwd=ROOT, timeout=90)
        if result.returncode == 0:
            result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '--cmd', f'set rtp+={ROOT}',
                                     '-l', str(ROOT / 'tests/ui.lua')], env=env, cwd=ROOT, timeout=45)
        if result.returncode == 0:
            result = subprocess.run(['nvim', '--headless', '-u', 'NONE', '-i', 'NONE', '--cmd', f'set rtp+={ROOT}',
                                     '-l', str(ROOT / 'tests/lazy.lua')], env=env, cwd=ROOT, timeout=30)
        tls_server.shutdown()
    server.shutdown()
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
