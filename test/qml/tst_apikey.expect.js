// The QML half proves the key never entered argv. This proves it still got
// where it was going: the mock records the X-Api-Key header it received.
const fs = require('node:fs');
const lines = fs.existsSync(process.env.REQUEST_LOG)
  ? fs.readFileSync(process.env.REQUEST_LOG, 'utf8').split('\n').filter(Boolean).map(JSON.parse) : [];
let failed = 0;
const check = (n, c, d) => { if (c) console.log('    PASS ' + n);
  else { console.log('    FAIL ' + n + (d ? ' -- ' + d : '')); failed++; } };

const info = lines.filter(l => l.kind === 'http' && l.path === '/printer/info');
check('both requests reached moonraker', info.length === 2, JSON.stringify(info));
check('the keyed request carried the header', info.some(l => l.apiKey === 's3cr3t-key'),
      JSON.stringify(info.map(l => l.apiKey)));
check('the keyless request carried none', info.some(l => l.apiKey === ''),
      JSON.stringify(info.map(l => l.apiKey)));
process.exit(failed === 0 ? 0 : 1);
