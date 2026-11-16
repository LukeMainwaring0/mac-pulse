"""Minimal warning cues: one timbre, two or three intentional pulses."""
import math, pathlib, struct, subprocess, wave
R=44100
ROOT=pathlib.Path(__file__).parent/'alerts'
def make(name,events,freq,warmth):
    out=[0.0]*int((max(t+d for t,d,g in events)+.16)*R)
    for at,d,g in events:
        for i in range(int((d+.16)*R)):
            t=i/R
            env=(math.sin(min(1,t/.008)*math.pi/2)**2)*math.exp(-t/(d*.58))
            if t>d:env*=math.exp(-(t-d)/.035)
            p=2*math.pi*freq*t
            v=(math.sin(p)+warmth*.25*math.sin(p*.5)+.10*math.sin(p*2)*math.exp(-t/.045))*env*g
            k=int(at*R)+i
            if k<len(out):out[k]+=v
    scale=min(.58/max(map(abs,out)),.14/math.sqrt(sum(v*v for v in out)/len(out)))
    path=ROOT/(name+'.wav')
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(R)
        f.writeframes(struct.pack('<'+'h'*len(out),*(round(v*scale*32767) for v in out)))
    subprocess.run(['afconvert','-f','AIFF','-d','BEI16',str(path),str(ROOT/(name+'.aiff'))],check=True)
make('FocusEssential',[(0,.14,.88),(.21,.22,1)],880,.8)
make('FocusClear',[(0,.10,.85),(.16,.10,.92),(.32,.17,1)],880,.65)
make('FocusFirm',[(0,.20,1),(.31,.20,1)],740,1.0)
