import re,sys,os
HERE=os.path.dirname(os.path.abspath(__file__))
def load_master():
    rows=[]
    for l in open(os.path.join(HERE,'master.txt'),encoding='utf8').read().split('\n'):
        if not l: continue
        n,idt,en=l.split('|',2); rows.append((int(n),idt,en))
    return rows
PH=re.compile(r'\{[a-z]+\}')
def load_lang(path):
    d={}
    for ln,l in enumerate(open(path,encoding='utf8').read().split('\n'),1):
        if not l.strip(): continue
        n,_,t=l.partition('|')
        if not n.strip().isdigit(): raise SystemExit(f'{path}:{ln}: bad line {l[:60]!r}')
        n=int(n)
        if n in d: raise SystemExit(f'{path}:{ln}: duplicate index {n}')
        d[n]=t.strip()
    return d
def check(lang):
    m=load_master(); d=load_lang(os.path.join(HERE,'trans',lang+'.txt'))
    errs=[]
    for n,idt,en in m:
        if n not in d: errs.append(f'missing {n} ({idt!r})'); continue
        t=d[n]
        if not t: errs.append(f'empty {n}')
        if set(PH.findall(t))!=set(PH.findall(idt)): errs.append(f'placeholder mismatch {n}: src {PH.findall(idt)} got {PH.findall(t)} :: {t!r}')
        if '$' in t or "\n" in t: errs.append(f'bad char in {n}')
    extra=set(d)-{n for n,_,_ in m}
    if extra: errs.append(f'unknown indices {sorted(extra)[:10]}')
    return errs
if __name__=='__main__':
    bad=0
    for lang in sys.argv[1:]:
        e=check(lang)
        print(lang,'OK' if not e else f'{len(e)} problems')
        for x in e[:25]: print('  ',x)
        bad+=bool(e)
    sys.exit(1 if bad else 0)
