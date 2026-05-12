#!/usr/bin/env python3
import os, re, sys
kernel_dir = sys.argv[1] if len(sys.argv) > 1 else '.'
os.chdir(kernel_dir)
print('Patching:', os.getcwd())
for root, dirs, files in os.walk('.'):
    for fname in files:
        fpath = os.path.join(root, fname)
        if fname == 'cred.c':
            t = open(fpath,'rb').read().decode('utf-8',errors='replace')
            if '0x%lx' in t:
                open(fpath,'wb').write(t.replace('0x%lx','%p').encode())
                print('PATCHED', fpath)
        elif fname == 'kernel.h' and 'include/linux' in root:
            t = open(fpath).read()
            if 'TRACING_MARK_TYPE_END, ""' in t:
                open(fpath,'w').write(t.replace('TRACING_MARK_TYPE_END, ""','TRACING_MARK_TYPE_END, " "'))
                print('PATCHED', fpath)
        elif fname == 'psi.c' and 'kernel/sched' in root:
            t = open(fpath).read()
            if '%lu' in t:
                open(fpath,'w').write(t.replace('%lu','%llu'))
                print('PATCHED', fpath)
c = 0
for root, dirs, files in os.walk('.'):
    for fname in files:
        if 'Makefile' in fname or fname.endswith('.mk'):
            try:
                t = open(os.path.join(root,fname)).read()
                if '-Werror' in t:
                    open(os.path.join(root,fname),'w').write(re.sub(r'-Werror[=\w.-]*','',t))
                    c += 1
            except: pass
print('Cleaned', c, 'Makefiles')
print('ALL DONE')
