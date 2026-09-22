// Local UI fixture server. Never connects to the shared Supabase database.
// node tests/preview-server.cjs, then /beta/?scenario=mentor or /beta/admin/?scenario=admin
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const types = {'.html':'text/html', '.css':'text/css', '.js':'text/javascript', '.svg':'image/svg+xml', '.png':'image/png', '.json':'application/json'};
http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const relative = decodeURIComponent(url.pathname).replace(/^\/beta\//, '').replace(/^\//, '');
  let file = path.resolve(root, relative || 'index.html');
  if (file !== root && !file.startsWith(root + path.sep)) {res.writeHead(403); return res.end();}
  if (fs.existsSync(file) && fs.statSync(file).isDirectory()) file = path.join(file, 'index.html');
  if (!fs.existsSync(file)) {res.writeHead(404); return res.end('Not found');}
  let body = fs.readFileSync(file);
  if (path.extname(file) === '.html') {
    const fixture = fs.readFileSync(path.join(__dirname, 'preview-fixtures.js'), 'utf8');
    body = Buffer.from(body.toString().replace('<head>', '<head><script>' + fixture + '</script>'));
  }
  res.writeHead(200, {'Content-Type':types[path.extname(file)] || 'text/plain', 'Cache-Control':'no-store',
    'Content-Security-Policy':"connect-src 'self'; script-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'"});
  res.end(body);
}).listen(8765, '127.0.0.1', () => console.log('Synthetic preview: http://127.0.0.1:8765/beta/?scenario=mentor (no production access)'));
