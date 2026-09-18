import wave, numpy as np, sys, json, os
base=sys.argv[1]
def rd(p):
    w=wave.open(p,'rb'); n=w.getnframes(); sr=w.getframerate(); ch=w.getnchannels()
    d=np.frombuffer(w.readframes(n),dtype=np.int16).astype(np.float64)
    if ch==2: d=d.reshape(-1,2).mean(1)
    return d/32768.0, sr
texts=[l.rstrip('\n') for l in open(base+"/g2p/matched.txt") if l.strip()]
rows=[]
for i,t in enumerate(texts,1):
    a,sra=rd(f"{base}/audio_native/native_{i:02d}.wav")
    b,srb=rd(f"{base}/audio_server/server_{i:02d}.wav")
    # best lag via FFT cross-correlation
    N=1<<int(np.ceil(np.log2(len(a)+len(b))))
    A=np.fft.rfft(a,N); B=np.fft.rfft(b,N)
    cc=np.fft.irfft(A*np.conj(B),N)
    cc=np.concatenate([cc[-(len(b)-1):],cc[:len(a)]])
    lag=int(np.argmax(cc))-(len(b)-1)
    # align
    if lag>=0: x,y=a[lag:],b
    else: x,y=a,b[-lag:]
    L=min(len(x),len(y)); x,y=x[:L],y[:L]
    ncc=float(np.dot(x,y)/(np.linalg.norm(x)*np.linalg.norm(y)+1e-12))
    diff=x-y
    rel=float(np.sqrt(np.mean(diff**2))/(np.sqrt(np.mean(y**2))+1e-12))
    rows.append(dict(i=i, text=t, sr_native=sra, sr_server=srb,
                     n_native=len(a), n_server=len(b), lag=lag,
                     ncc=round(ncc,4), rel_rms_diff=round(rel,4),
                     dur_native=round(len(a)/sra,3), dur_server=round(len(b)/srb,3)))
print(f"{'#':>2} {'ncc':>7} {'relRMS':>7} {'lag':>6} {'durN':>6} {'durS':>6}  text")
for r in rows:
    print(f"{r['i']:>2} {r['ncc']:>7.4f} {r['rel_rms_diff']:>7.4f} {r['lag']:>6} {r['dur_native']:>6.2f} {r['dur_server']:>6.2f}  {r['text'][:52]}")
nc=[r['ncc'] for r in rows]
print(f"\nmedian ncc = {np.median(nc):.4f}   min = {min(nc):.4f}   max = {max(nc):.4f}")
print(f"median relRMS = {np.median([r['rel_rms_diff'] for r in rows]):.4f}")
json.dump(rows, open(base+"/audio_compare.json","w"), indent=1)
