#!/usr/bin/env node
// Builds the one-file app: src/app.html with the engine and the page script inlined.
// `node tools/build.js` writes Note-Position-Volume-Fixer.html at the top of the repository.
'use strict';
const fs = require('fs');
const path = require('path');
const root = path.join(__dirname, '..');
const read = f => fs.readFileSync(path.join(root, f), 'utf8');
const inline = js => {
  if (/<\/script/i.test(js)) throw new Error('A script contains </script>');
  return '<script>\n' + js + '\n</script>';
};
const engine = read('src/engine.js');
const version = /const VERSION = '([^']+)'/.exec(engine)[1];
const html = read('src/app.html')
  .replace('<!--ENGINE-->', () => inline(engine))
  .replace('<!--APP-->', () => inline(read('src/app.js')))
  .replace('<title>Note Fixer</title>', () => '<title>Note Fixer</title>\n<meta name="generator" content="Note Position &amp; Volume Fixer ' + version + '">');
const out = path.join(root, 'Note-Position-Volume-Fixer.html');
fs.writeFileSync(out, html);
console.log('wrote ' + path.relative(root, out) + ' (' + Math.round(html.length / 1024) + ' KB, version ' + version + ')');
