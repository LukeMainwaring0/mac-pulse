#!/usr/bin/env python3
"""Loopback-only Mac Pulse alert sound picker. No external dependencies."""
import http.server, json, pathlib, secrets, shutil, subprocess, tempfile, os
from urllib.parse import urlparse
ROOT = pathlib.Path(__file__).parent
SOUNDS = ROOT / 'alerts'
CONFIG = pathlib.Path.home() / 'Library/Application Support/Mac Pulse/alert-sound.json'
CACHE = pathlib.Path(tempfile.mkdtemp(prefix='mac-pulse-sounds-'))
TOKEN = secrets.token_urlsafe(24)
NAMES = ['FocusEssential', 'FocusClear', 'FocusFirm', 'FocusPriority', 'FocusCritical', 'FocusDepth', 'FocusImpact', 'FocusInsistent', 'Focus', 'Signal', 'Notice', 'Tension', 'Resolve', 'GlassPulse', 'Tripwire', 'Interrupt', 'Watchdog', 'Pressure', 'Relay', 'Sentinel', 'UrgentPulse', 'PulseTight', 'PulseLower', 'PulseSharper', 'PulseDry', 'PulseGrit', 'PulseTriplets', 'PulseInsistent', 'PulseAccelerating']
for name in NAMES:
    subprocess.run(['afconvert', '-f', 'WAVE', '-d', 'LEI16', str(SOUNDS / (name+'.aiff')), str(CACHE / (name+'.wav'))], check=True)
class Handler(http.server.BaseHTTPRequestHandler):
    def reply(self, data, kind='application/json', status=200):
        self.send_response(status)
        self.send_header('Content-Type', kind)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        path = urlparse(self.path).path
        if path == '/': return self.reply((ROOT/'index.html').read_bytes(), 'text/html; charset=utf-8')
        if path == '/api/sounds':
            try: selected = json.loads(CONFIG.read_text()).get('name')
            except (OSError, ValueError): selected = None
            return self.reply(json.dumps(dict(names=NAMES, selected=selected, token=TOKEN)).encode())
        if path.startswith('/audio/') and path[7:-4] in NAMES and path.endswith('.wav'):
            return self.reply((CACHE / (path[7:])).read_bytes(), 'audio/wav')
        self.reply(b'Not found', 'text/plain', 404)
    def do_POST(self):
        if self.path != '/api/select' or self.headers.get('X-Picker-Token') != TOKEN:
            return self.reply(b'Forbidden', 'text/plain', 403)
        try:
            length = int(self.headers.get('Content-Length', '0'))
            if not 0 < length < 1024: raise ValueError()
            name = json.loads(self.rfile.read(length))['name']
            if name not in NAMES: raise ValueError()
            target = pathlib.Path.home() / 'Library/Sounds' / ('MacPulse-'+name+'.aiff')
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(SOUNDS/(name+'.aiff'), target)
            CONFIG.parent.mkdir(parents=True, exist_ok=True)
            tmp = CONFIG.with_suffix('.tmp')
            tmp.write_text(json.dumps(dict(name=name, filename=target.name)))
            tmp.replace(CONFIG)
            self.reply(json.dumps(dict(selected=name)).encode())
        except (ValueError, KeyError): self.reply(b'Invalid sound', 'text/plain', 400)
    def log_message(self, *args): pass
server = http.server.ThreadingHTTPServer(('127.0.0.1', int(os.environ.get('PICKER_PORT', '0'))), Handler)
url = 'http://localhost:'+str(server.server_port)
(ROOT/'runtime.json').write_text(json.dumps(dict(url=url)))
print(url, flush=True)
server.serve_forever()
