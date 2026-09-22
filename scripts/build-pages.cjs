// Dependency-free, allowlisted output for a separate GitHub Pages deployment.
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const output = path.resolve(root, 'dist');
if (output !== path.join(root, 'dist') || path.dirname(output) !== root) throw new Error('Output must be this project’s dist directory.');
if (fs.existsSync(output) && fs.lstatSync(output).isSymbolicLink()) throw new Error('Refusing a linked output directory.');
// The resolved, checked target is a disposable build directory, never a source directory.
fs.rmSync(output, {recursive:true, force:true});
const files = ['index.html','admin/index.html','sw.js','manifest.json','icon.svg',
  'assets/mentor.css','assets/admin.css','assets/design-system.css',
  'assets/icon-192.png','assets/icon-512.png','assets/apple-touch-icon.png'];
for (const file of files) {
  const target = path.join(output, file);
  fs.mkdirSync(path.dirname(target), {recursive:true});
  fs.copyFileSync(path.join(root, file), target);
}
fs.writeFileSync(path.join(output, '.nojekyll'), '');
console.log(`GitHub Pages files are ready in ${output}. No domain override or test fixtures included.`);
