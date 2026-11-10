import os,sys
sys.path.insert(0,os.path.dirname(os.path.abspath(__file__)))
from validate import load_master,load_lang
HERE=os.path.dirname(os.path.abspath(__file__))
OUT=sys.argv[1]
os.makedirs(OUT,exist_ok=True)
master=load_master()
import master_src
keys=[k for k,_,_ in master_src.ALL]
langs=['en','ms','zh','ja','ko','ar','hi','es','fr','de','pt','ru','tr','vi','th']
def esc(s): return s.replace('\\','\\\\').replace("'","\\'").replace('$','\\$')
def cls(code): return 'kStrings'+code.capitalize()
def write(code,items,header):
    with open(os.path.join(OUT,code+'.dart'),'w',encoding='utf8') as f:
        f.write(f"// GENERATED FILE – {header}\n// Lihat tools di README untuk cara menambah/mengubah terjemahan.\n\n")
        f.write(f"const Map<String, String> {cls(code)} = {{\n")
        for k,v in items: f.write(f"  '{esc(k)}': '{esc(v)}',\n")
        f.write("};\n")
# id: only structural keys
idm=[(k,idt) for (k,idt,en) in master_src.ALL if k!=idt]
write('id',idm,'Bahasa Indonesia (hanya kunci khusus; teks lain memakai kunci aslinya)')
for code in langs:
    d=load_lang(os.path.join(HERE,'trans',code+'.txt'))
    write(code,[(k,d[i]) for i,k in enumerate(keys,1)],code)
with open(os.path.join(OUT,'translations.dart'),'w',encoding='utf8') as f:
    f.write("// GENERATED FILE\n")
    for code in ['id']+langs: f.write(f"import '{code}.dart';\n")
    f.write("\n/// kode bahasa -> (kunci -> teks)\nconst Map<String, Map<String, String>> translations = {\n")
    for code in ['id']+langs: f.write(f"  '{code}': {cls(code)},\n")
    f.write("};\n")
print('ok')
