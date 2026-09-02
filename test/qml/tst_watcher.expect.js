// Asserts what the mock Moonraker was actually asked for. The QML half checks
// what the watcher displayed; this checks the wire, so a watcher that renders
// a convincing activity row without ever issuing a request still fails.
const fs = require('node:fs');

const entries = fs.readFileSync(process.env.REQUEST_LOG, 'utf8')
  .split('\n').filter(Boolean).map(JSON.parse);

const metascans = entries
  .filter(e => e.kind === 'http' && e.path === '/server/files/metascan')
  .map(e => e.query.filename);

let failed = 0;
const check = (name, cond, detail) => {
  if (cond) { console.log('    PASS ' + name); }
  else { console.log('    FAIL ' + name + (detail ? ' -- ' + detail : '')); failed++; }
};

const count = (f) => metascans.filter(x => x === f).length;

// Path sent to Moonraker must be relative to the watch root, with nesting
// preserved -- this is the mapping that only holds because the watched
// directory is the same share the printers mount as their gcodes root.
check('root file scanned on both printers', count('root.gcode') === 2, `saw ${count('root.gcode')}`);
check('nested path kept relative', count('nested/deep.gcode') === 2, `saw ${count('nested/deep.gcode')}`);
check('file in new subdirectory scanned', count('fresh_dir/new.gcode') === 2, `saw ${count('fresh_dir/new.gcode')}`);

check('no absolute paths sent', !metascans.some(f => f.startsWith('/')), metascans.join(', '));
check('non-gcode file never requested', count('notes.txt') === 0);
check('hidden-directory file never requested',
  !metascans.some(f => f.includes('.hidden')), metascans.join(', '));

// POST, not GET -- Moonraker's metascan only accepts POST.
const badMethod = entries.filter(e => e.path === '/server/files/metascan' && e.method !== 'POST');
check('metascan issued as POST', badMethod.length === 0, `${badMethod.length} non-POST`);

process.exit(failed === 0 ? 0 : 1);
