import time, json, urllib.request, sys
lines=[l.rstrip("\n") for l in open("/private/tmp/claude-501/-Users-guymorita-Dev/0da5dc1b-17f5-4899-b383-ffbf768075ea/scratchpad/native-spike/latency_corpus.txt") if l.strip()]
res=[]
for i,t in enumerate(lines,1):
    body=json.dumps({"model":"kokoro","input":t,"voice":"af_bella","speed":1.0,
                     "response_format":"pcm","stream":True}).encode()
    req=urllib.request.Request("http://127.0.0.1:8880/v1/audio/speech", data=body,
                               headers={"Content-Type":"application/json"})
    t0=time.time(); first=None; total=0
    with urllib.request.urlopen(req) as r:
        while True:
            c=r.read(4096)
            if not c: break
            if first is None and len(c)>0: first=time.time()-t0
            total+=len(c)
    dt=time.time()-t0
    res.append((i,first,dt,total))
    print(f"{i:02d} ttfa={first:.3f}s total={dt:.3f}s bytes={total} audio={total/2/24000:.2f}s")
import statistics
warm=[r[1] for r in res[1:]]
print("\nserver TTFA warm median = %.3fs  (runs: %s)" % (statistics.median(warm), [round(x,3) for x in warm]))
print("server TOTAL warm median = %.3fs" % statistics.median([r[2] for r in res[1:]]))
