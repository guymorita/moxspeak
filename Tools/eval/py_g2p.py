import json, sys
from misaki import en, espeak
try:
    fb = espeak.EspeakFallback(british=False)
except Exception as e:
    print("espeak fallback unavailable:", e, file=sys.stderr)
    fb = None
g2p = en.G2P(trf=False, british=False, fallback=fb, unk='')
out=[]
for line in open(sys.argv[1], encoding='utf-8'):
    line=line.rstrip('\n')
    if not line: continue
    ps, tokens = g2p(line)
    out.append({"text": line, "phonemes": ps})
print(json.dumps(out, ensure_ascii=False, indent=1))
