// Which endpoint each button actually hit, and in what order. The QML half
// only proves requests arrived; this proves they were the right ones.
const fs = require('node:fs');
const entries = fs.readFileSync(process.env.REQUEST_LOG, 'utf8')
  .split('\n').filter(Boolean).map(JSON.parse);
let failed = 0;
const check = (n, c, d) => { if (c) console.log('    PASS ' + n);
  else { console.log('    FAIL ' + n + (d ? ' -- ' + d : '')); failed++; } };

const posts = entries.filter(e => e.kind === 'http' && e.method === 'POST').map(e => e.path);

check('exactly four actions reached the printer', posts.length === 4, posts.join(' -> '));
check('order is pause, cancel, e-stop, firmware restart',
  JSON.stringify(posts) === JSON.stringify([
    '/printer/print/pause',
    '/printer/print/cancel',
    '/printer/emergency_stop',
    '/printer/firmware_restart',
  ]), posts.join(' -> '));

// Mid-print the shared button must pause, never resume.
check('never issued resume while printing', !posts.includes('/printer/print/resume'));
// Confirm-guarded actions must not fire twice for two presses.
check('cancel sent once', posts.filter(p => p === '/printer/print/cancel').length === 1);
check('emergency stop sent once', posts.filter(p => p === '/printer/emergency_stop').length === 1);

process.exit(failed === 0 ? 0 : 1);
