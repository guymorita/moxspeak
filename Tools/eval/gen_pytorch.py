import json, wave, numpy as np, torch, time, sys
from kokoro import KModel
base="/private/tmp/claude-501/-Users-guymorita-Dev/0da5dc1b-17f5-4899-b383-ffbf768075ea/scratchpad/native-spike"
km = KModel(repo_id='hexgrad/Kokoro-82M',
            config="/Users/guymorita/Dev/Kokoro-FastAPI/api/src/models/v1_0/config.json",
            model="/Users/guymorita/Dev/Kokoro-FastAPI/api/src/models/v1_0/kokoro-v1_0.pth").eval()
voice = torch.load("/Users/guymorita/Dev/Kokoro-FastAPI/api/src/voices/v1_0/af_bella.pt", map_location='cpu', weights_only=True)
py={d["text"]:d["phonemes"] for d in json.load(open(base+"/g2p/py_out.json"))}
texts=[l.rstrip("\n") for l in open(base+"/g2p/matched.txt") if l.strip()]
rep=[]
for i,t in enumerate(texts,1):
    ps=py[t]
    n=len(list(filter(lambda x: x is not None,[km.vocab.get(p) for p in ps])))
    ref_s = voice[n]
    t0=time.time()
    with torch.no_grad():
        audio = km(ps, ref_s, speed=1.0)
    dt=time.time()-t0
    a=audio.numpy()
    w=wave.open(f"{base}/audio_pytorch/torch_{i:02d}.wav",'wb'); w.setnchannels(1); w.setsampwidth(2); w.setframerate(24000)
    w.writeframes((np.clip(a,-1,1)*32767).astype(np.int16).tobytes()); w.close()
    rep.append(dict(i=i,text=t,gen_sec=dt,samples=len(a),ntok=n))
    print(f"{i:02d} gen={dt:.3f}s audio={len(a)/24000:.2f}s ntok={n}")
json.dump(rep, open(base+"/audio_pytorch/torch_report.json","w"), indent=1)
