# Prints the distinct problems in e2e/results/results.json, with how many tests hit each one.
import glob
import json
import re
import sys
from collections import Counter

sys.stdout.reconfigure(encoding='utf-8')
seen = Counter()
names = {}


def walk(s):
    for sp in s.get('specs', []):
        for t in sp['tests']:
            for r in t['results']:
                for e in r.get('errors', []):
                    msg = re.sub(r'\x1b\[[0-9;]*m', '', e.get('message', ''))
                    for line in msg.split('\n'):
                        line = line.strip()
                        if line.startswith('+   "') or line.startswith('+ "'):
                            key = re.sub(r'[0-9a-f]{8}-[0-9a-f-]{27}', '<id>', line)
                            seen[key] += 1
                            names.setdefault(key, sp['title'] + ' [' + t['projectName'] + ']')
                    if 'Error:' in msg and '+   "' not in msg:
                        first = msg.split('\n')[0][:200]
                        seen[first] += 1
                        names.setdefault(first, sp['title'] + ' [' + t['projectName'] + ']')
    for c in s.get('suites', []):
        walk(c)


for f in sorted(glob.glob('e2e/results/results*.json')):
    d = json.load(open(f, encoding='utf-8'))
    print(f, d['stats'])
    for s in d['suites']:
        walk(s)
for k, n in seen.most_common():
    print(f'{n:4d}  {k[:400]}\n      e.g. {names[k]}')
