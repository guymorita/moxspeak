import json,sys,difflib
py={d["text"]:d["phonemes"] for d in json.load(open(sys.argv[1],encoding='utf-8'))}
sw={d["text"]:d["phonemes"] for d in json.load(open(sys.argv[2],encoding='utf-8'))}
order=[l.rstrip('\n') for l in open(sys.argv[3],encoding='utf-8') if l.strip()]
match=0; mismatches=[]
for t in order:
    a,b=py.get(t),sw.get(t)
    if a==b: match+=1
    else: mismatches.append((t,a,b))
print(f"TOTAL={len(order)}  EXACT_MATCH={match}  RATE={match/len(order)*100:.1f}%\n")
for t,a,b in mismatches:
    r=difflib.SequenceMatcher(None,a or '',b or '').ratio()
    print(f"--- {t}\n  PY : {a}\n  SW : {b}\n  charsim={r:.3f}\n")
