import fs from 'node:fs';
import vm from 'node:vm';
const src = fs.readFileSync(new URL('./pek-core.js', import.meta.url), 'utf8');
const PekCore = new Function(src + '; return PekCore;')();
const dir = process.argv[2];
let bad = 0;
const t = (name, ok) => { console.log((ok ? 'PASS ' : 'FAIL ') + name); if (!ok) bad++; };
for (const f of fs.readdirSync(dir).filter(x => x.endsWith('.PEK'))) {
  const buf = new Uint8Array(fs.readFileSync(dir + '/' + f));
  const pek = await PekCore.read(buf);
  const owner = PekCore.check(pek, { owner: true });
  const pub = PekCore.check(pek, { owner: false });
  t(f + ' reads, id=' + pek.id + ' files=' + pek.files.length, pek.files.length >= 4);
  t(f + ' owner check clean', owner.problems.length === 0);
  t(f + ' public check refuses built-in id', pub.problems.length > 0);
  console.log('   info:', JSON.stringify(owner.info.lines));
  // tamper tests
  const flip = (i) => { const c = buf.slice(); c[i] ^= 1; return c; };
  for (const [label, data] of [['flipped data byte', flip(100)], ['flipped footer', flip(buf.length - 5)], ['truncated', buf.slice(0, buf.length - 7)], ['extra byte', Uint8Array.from([...buf, 0])], ['zip header', Uint8Array.from([0x50,0x4b,3,4,...buf.slice(4)])]]) {
    let rejected = false; try { await PekCore.read(data); } catch (e) { rejected = e instanceof PekCore.Reject; }
    t(f + ' rejects ' + label, rejected);
  }
}
// a plugin the public may upload: rename id by building a custom check
const buf = new Uint8Array(fs.readFileSync(dir + '/weather.PEK'));
const w = await PekCore.read(buf);
w.id = 'my-weather';
const r = PekCore.check(w, { owner: false });
t('renamed weather passes public check', r.problems.length === 0);
console.log(bad ? 'FAILURES: ' + bad : 'ALL OK');
process.exit(bad ? 1 : 0);
