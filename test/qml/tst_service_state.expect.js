// The QML half proves Service tracked a notification id; this proves the id
// actually reached the next command line as -r, which is what makes the
// second toast replace the first instead of stacking under it.
const fs = require('node:fs');
const lines = fs.existsSync(process.env.NOTIFY_LOG)
  ? fs.readFileSync(process.env.NOTIFY_LOG, 'utf8').split('\n').filter(Boolean) : [];
let failed = 0;
const check = (n, c, d) => { if (c) console.log('    PASS ' + n);
  else { console.log('    FAIL ' + n + (d ? ' -- ' + d : '')); failed++; } };

const firstIdx = lines.findIndex(l => l.includes('ToastA'));
const second = lines.find(l => l.includes('ToastB')) || '';
check('both notifications were sent', firstIdx !== -1 && second !== '', lines.join(' | '));
check('the first opens a new toast', !/ -r /.test(lines[firstIdx] || ''), lines[firstIdx]);
check('every send asks for the id back', lines.every(l => / -p( |$)/.test(l)), lines.join(' | '));
// The stub numbers its replies by invocation, so the first send's id is its
// 1-based position in the log.
check('the second replaces the first by id', second.includes(`-r ${firstIdx + 1} `), second);
process.exit(failed === 0 ? 0 : 1);
