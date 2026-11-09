# Sets "select plan(N);" in pgTAP files to the number of assertions they contain.
import re, sys
for p in sys.argv[1:]:
    s = open(p, encoding='utf-8').read()
    n = len(re.findall(r'^select (ok|is|isnt|throws_ok|lives_ok|results_eq|cmp_ok)\(', s, re.M))
    s = re.sub(r'select plan\(\d+\);', f'select plan({n});', s, count=1)
    open(p, 'w', encoding='utf-8').write(s)
    print(p, n)
