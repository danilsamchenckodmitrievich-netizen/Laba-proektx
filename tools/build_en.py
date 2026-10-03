#!/usr/bin/env python3
"""Собирает английскую версию сайта en/index.html из index.html.

Каждый кусок текста с кириллицей (между кавычками, тегами и ${…}) заменяется
переводом из i18n/en.json. Код сайта не меняется, поэтому английская версия
работает так же, как русская. После правок index.html запустите:

    python3 tools/build_en.py

Скрипт покажет новые фразы без перевода — добавьте их в i18n/en.json."""
import json,re,sys,os
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CYR=re.compile('[А-Яа-яЁё]')
DELIM=set("'\"`<>${}\n")

def tokens(s):
    out,buf=[],[]
    for ch in s:
        if ch in DELIM:
            if buf:out.append(''.join(buf));buf=[]
            out.append(ch)
        else:buf.append(ch)
    if buf:out.append(''.join(buf))
    return out

def main():
    src=open(os.path.join(ROOT,'index.html'),encoding='utf-8').read()
    tr=json.load(open(os.path.join(ROOT,'i18n','en.json'),encoding='utf-8'))
    missing=[]
    out=[]
    nocom=set(tokens(re.sub(r'/\*[\s\S]*?\*/','',src)))
    for t in tokens(src):
        if CYR.search(t):
            if t in tr:t=tr[t]
            elif '//' not in t and t in nocom:missing.append(t)
        out.append(t)
    s=''.join(out)
    # то, что зависит от языка, но не является текстом
    rep=[('<html lang="ru">','<html lang="en">'),
         ("new Intl.NumberFormat('ru-RU',{","new Intl.NumberFormat('en-GB',{useGrouping:false,"),
         ("'ru-RU'","'en-GB'"),
         (".replace('.',',')",".replace(',','.')"),
         ('№ ','No. '),('№','No.'),('«','“'),('»','”'),
         ('<b>Lab</b> <span>Sirius</span>','<b>Sirius</b> <span>Lab</span>'),
         ('href="manifest.webmanifest"','href="../manifest.webmanifest"'),
         ('href="icon-192.png"','href="../icon-192.png"'),
         ('href="apple-touch-icon.png"','href="../apple-touch-icon.png"'),
         ("register('sw.js')","register('../sw.js')"),
         ("'zhurnal-laboratoriya-sirius.csv'","'class-journal-sirius-lab.csv'")]
    for a,b in rep:
        if a not in s:print('нет в файле:',a,file=sys.stderr)
        s=s.replace(a,b)
    s=re.sub(r"const plural=\(n,a,b,c\)=>\{[^\n]*\};","const plural=(n,a,b,c)=>n===1?a:c;",s)
    s=re.sub(r"const LANG=\{[^\n]*\};","const LANG={code:'en',other:'../',label:'RU',name:'Русская версия'};",s)
    os.makedirs(os.path.join(ROOT,'en'),exist_ok=True)
    open(os.path.join(ROOT,'en','index.html'),'w',encoding='utf-8').write(s)
    print('en/index.html готов. Без перевода:',len(missing))
    for m in missing[:50]:print('  ',repr(m))
    return 1 if missing else 0
sys.exit(main())
