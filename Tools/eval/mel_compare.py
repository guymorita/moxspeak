import wave, numpy as np, sys, json
base=sys.argv[1]; SR=24000
def rd(p):
    w=wave.open(p,'rb'); n=w.getnframes(); ch=w.getnchannels()
    d=np.frombuffer(w.readframes(n),dtype=np.int16).astype(np.float64)
    if ch==2: d=d.reshape(-1,2).mean(1)
    return d/32768.0
def melfb(nfft=1024,nmel=64,sr=SR,fmin=50,fmax=11000):
    def h2m(f): return 2595*np.log10(1+f/700)
    def m2h(m): return 700*(10**(m/2595)-1)
    pts=m2h(np.linspace(h2m(fmin),h2m(fmax),nmel+2))
    bins=np.floor((nfft+1)*pts/sr).astype(int)
    fb=np.zeros((nmel,nfft//2+1))
    for i in range(nmel):
        l,c,r=bins[i],bins[i+1],bins[i+2]
        if c==l: c=l+1
        if r==c: r=c+1
        fb[i,l:c]=np.linspace(0,1,c-l); fb[i,c:r]=np.linspace(1,0,r-c)
    return fb
FB=melfb()
def stftmag(x,n=1024,h=256):
    win=np.hanning(n)
    if len(x)<n: x=np.pad(x,(0,n-len(x)))
    fr=1+(len(x)-n)//h
    return np.array([np.abs(np.fft.rfft(x[i*h:i*h+n]*win)) for i in range(fr)])
def bestlag(a,b):
    N=1<<int(np.ceil(np.log2(len(a)+len(b))))
    cc=np.fft.irfft(np.fft.rfft(a,N)*np.conj(np.fft.rfft(b,N)),N)
    cc=np.concatenate([cc[-(len(b)-1):],cc[:len(a)]]); return int(np.argmax(cc))-(len(b)-1)
def cmp(pa,pb):
    a,b=rd(pa),rd(pb)
    lag=bestlag(a,b)
    x,y=(a[lag:],b) if lag>=0 else (a,b[-lag:])
    L=min(len(x),len(y)); x,y=x[:L],y[:L]
    x=x/(np.sqrt(np.mean(x**2))+1e-12); y=y/(np.sqrt(np.mean(y**2))+1e-12)
    A,B=stftmag(x)@FB.T, stftmag(y)@FB.T
    F=min(len(A),len(B)); A,B=A[:F],B[:F]
    la,lb=20*np.log10(np.maximum(A,1e-5)),20*np.log10(np.maximum(B,1e-5))
    lsd=float(np.mean(np.sqrt(np.mean((la-lb)**2,axis=1))))
    cos=float(np.sum(A*B)/(np.linalg.norm(A)*np.linalg.norm(B)+1e-12))
    # frame energy envelope correlation
    ea,eb=A.sum(1),B.sum(1)
    env=float(np.corrcoef(ea,eb)[0,1])
    return lsd,cos,env
texts=[l.rstrip("\n") for l in open(base+"/g2p/matched.txt") if l.strip()]
for name,(pa,pb) in {"native_vs_pytorch":("audio_native/native_","audio_pytorch/torch_"),
                     "server_vs_pytorch":("audio_server/server_","audio_pytorch/torch_")}.items():
    r=np.array([cmp(f"{base}/{pa}{i:02d}.wav",f"{base}/{pb}{i:02d}.wav") for i in range(1,len(texts)+1)])
    print(f"### {name}: melLSD median={np.median(r[:,0]):.2f} dB (max {r[:,0].max():.2f}) | melCos median={np.median(r[:,1]):.4f} (min {r[:,1].min():.4f}) | envCorr median={np.median(r[:,2]):.4f} (min {r[:,2].min():.4f})")
    print("   per-item melLSD:", np.round(r[:,0],2).tolist())
