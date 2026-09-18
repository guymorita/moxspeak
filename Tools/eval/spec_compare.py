import wave, numpy as np, sys, json
base=sys.argv[1]
def rd(p):
    w=wave.open(p,'rb'); n=w.getnframes(); ch=w.getnchannels()
    d=np.frombuffer(w.readframes(n),dtype=np.int16).astype(np.float64)
    if ch==2: d=d.reshape(-1,2).mean(1)
    return d/32768.0
def stftmag(x,n=1024,h=256):
    win=np.hanning(n)
    if len(x)<n: x=np.pad(x,(0,n-len(x)))
    frames=1+(len(x)-n)//h
    S=np.empty((frames,n//2+1))
    for i in range(frames):
        S[i]=np.abs(np.fft.rfft(x[i*h:i*h+n]*win))
    return S
def bestlag(a,b):
    N=1<<int(np.ceil(np.log2(len(a)+len(b))))
    cc=np.fft.irfft(np.fft.rfft(a,N)*np.conj(np.fft.rfft(b,N)),N)
    cc=np.concatenate([cc[-(len(b)-1):],cc[:len(a)]])
    return int(np.argmax(cc))-(len(b)-1)
def compare(pa,pb):
    a,b=rd(pa),rd(pb)
    lag=bestlag(a,b)
    if lag>=0: x,y=a[lag:],b
    else: x,y=a,b[-lag:]
    L=min(len(x),len(y)); x,y=x[:L],y[:L]
    ncc=float(np.dot(x,y)/(np.linalg.norm(x)*np.linalg.norm(y)+1e-12))
    relrms=float(np.sqrt(np.mean((x-y)**2))/(np.sqrt(np.mean(y**2))+1e-12))
    # scale-invariant: normalize RMS (server normalizes amplitude)
    xs=x/ (np.sqrt(np.mean(x**2))+1e-12); ys=y/(np.sqrt(np.mean(y**2))+1e-12)
    relrms_n=float(np.sqrt(np.mean((xs-ys)**2))/(np.sqrt(np.mean(ys**2))+1e-12))
    A,B=stftmag(x),stftmag(y)
    F=min(len(A),len(B)); A,B=A[:F],B[:F]
    cos=float(np.sum(A*B)/(np.linalg.norm(A)*np.linalg.norm(B)+1e-12))
    eps=1e-8
    lsd=float(np.mean(np.sqrt(np.mean((20*np.log10(A+eps)-20*np.log10(B+eps))**2,axis=1))))
    return ncc,relrms,relrms_n,cos,lsd,L
texts=[l.rstrip("\n") for l in open(base+"/g2p/matched.txt") if l.strip()]
pairs={"native_vs_pytorch":("audio_native/native_","audio_pytorch/torch_"),
       "server_vs_pytorch":("audio_server/server_","audio_pytorch/torch_")}
out={}
for name,(pa,pb) in pairs.items():
    rows=[]
    for i in range(1,len(texts)+1):
        rows.append(compare(f"{base}/{pa}{i:02d}.wav", f"{base}/{pb}{i:02d}.wav"))
    arr=np.array([r[:5] for r in rows])
    out[name]=dict(ncc=list(np.round(arr[:,0],4)), specCos=list(np.round(arr[:,3],4)),
                   lsd_dB=list(np.round(arr[:,4],2)), relrms=list(np.round(arr[:,1],3)),
                   relrms_norm=list(np.round(arr[:,2],3)))
    print(f"\n### {name}")
    print(f"  median ncc          = {np.median(arr[:,0]):.4f}")
    print(f"  median relRMS       = {np.median(arr[:,1]):.4f}")
    print(f"  median relRMS(normd)= {np.median(arr[:,2]):.4f}")
    print(f"  median specCos      = {np.median(arr[:,3]):.4f}  (min {arr[:,3].min():.4f})")
    print(f"  median LSD          = {np.median(arr[:,4]):.2f} dB (max {arr[:,4].max():.2f})")
json.dump(out, open(base+"/spec_compare.json","w"), indent=1)
