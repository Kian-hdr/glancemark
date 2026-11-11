import { createHash } from 'node:crypto';
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [input, output] = process.argv.slice(2);
if (!input || !output) throw Error('Usage: node Generate.mjs path/to/extracted/package output.swift');

const regexPath = resolve(input, 'regex.js');
const licensePath = resolve(input, 'LICENSE');
const digest = createHash('sha256').update(readFileSync(regexPath)).digest('hex');
if (digest !== '3bcbb3836a4e76f0f343c34d223ddd9eac83cc73a4e2c7a1118ef0829bc9129b') throw Error('Expected github-slugger 2.0.0 regex.js');
const { regex } = await import(pathToFileURL(regexPath).href);

const ranges = [];
for (let value = 0; value <= 0x10ffff; value++) {
  if (value >= 0xd800 && value <= 0xdfff) continue; // Swift strings contain valid scalars.
  regex.lastIndex = 0;
  if (regex.test(String.fromCodePoint(value))) continue;
  const previous = ranges.at(-1);
  if (previous && previous[1] === value - 1) previous[1] = value;
  else ranges.push([value, value]);
}
const pairs = ranges.flat().map(value => '0x' + value.toString(16).toUpperCase());
const lines = [];
for (let i = 0; i < pairs.length; i += 12) lines.push('        ' + pairs.slice(i, i + 12).join(', ') + ',');
const license = readFileSync(licensePath, 'utf8').trimEnd().split('\n').map(line => line ? '// ' + line : '//').join('\n');
writeFileSync(output, `// Generated from github-slugger 2.0.0 by Tests/Fixtures/HeadingSlugs/Generate.mjs.
// Source: https://github.com/Flet/github-slugger/tree/3461c4350868329c8530904d170358bca1d31448
${license}

enum GitHubHeadingScalars {
    private static let allowedEndpoints: [UInt32] = [
${lines.join('\n')}
    ]

    static func contains(_ value: UInt32) -> Bool {
        var low = 0
        var high = allowedEndpoints.count / 2
        while low < high {
            let middle = (low + high) / 2
            let index = middle * 2
            if value < allowedEndpoints[index] {
                high = middle
            } else if value > allowedEndpoints[index + 1] {
                low = middle + 1
            } else {
                return true
            }
        }
        return false
    }
}
`);
