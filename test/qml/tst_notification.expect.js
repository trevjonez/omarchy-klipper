// The QML half proves a notification object was built; this proves the real
// command line was executed, argv and all.
const fs = require('node:fs');
const lines = fs.existsSync(process.env.NOTIFY_LOG)
  ? fs.readFileSync(process.env.NOTIFY_LOG, 'utf8').split('\n').filter(Boolean) : [];
let failed = 0;
const check = (n, c, d) => { if (c) console.log('    PASS ' + n);
  else { console.log('    FAIL ' + n + (d ? ' -- ' + d : '')); failed++; } };
check('omarchy-notification-send was invoked', lines.length >= 1, `${lines.length} invocations`);
const argv = lines[0] || '';
check('passes an urgency flag', /-u \w+/.test(argv), argv);
check('names the printer', argv.includes('Voron'), argv);
check('names the finished file', argv.includes('demo.gcode'), argv);
process.exit(failed === 0 ? 0 : 1);
