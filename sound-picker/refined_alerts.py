"""Restrained pulse alerts: rounded transients, harmonic resonance, no sirens."""
import math, pathlib, struct, subprocess, wave
R=44100
ROOT=pathlib.Path(__file__).parent/'alerts'
def make(name, events, frequency, warmth, shimmer):
    out=[0.0]*int((max(t+d for t,d,g in events)+.16)*R)
    for onset,duration,gain in events:
        for i in range(int((duration+.16)*R)):
            t=i/R
            attack=math.sin(min(1,t/.009)*math.pi/2)**2
            decay=math.exp(-t/(duration*.55))
            release=1 if t<=duration else math.exp(-(t-duration)/.026)
            phase=2*math.pi*frequency*t
            # A stable fundamental; high partials disappear before the body.
            body=math.sin(phase)+warmth*.22*math.sin(phase*.5)
            sheen=shimmer*.17*math.sin(phase*3)*math.exp(-t/.025)
            second=.12*math.sin(phase*2)*math.exp(-t/.07)
            value=(body+sheen+second)*attack*decay*release*gain
            idx=int(onset*R)+i
            if idx<len(out):out[idx]+=value
    peak=max(map(abs,out));rms=math.sqrt(sum(v*v for v in out)/len(out))
    scale=min(.55/peak,.13/rms)
    samples=[round(v*scale*32767) for v in out]
    path=ROOT/(name+'.wav')
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(R)
        f.writeframes(struct.pack('<'+'h'*len(samples),*samples))
    subprocess.run(['afconvert','-f','AIFF','-d','BEI16',str(path),str(ROOT/(name+'.aiff'))],check=True)
make('Focus',[(0,.105,.86),(.16,.105,.93),(.32,.16,1)],880,.5,.5)
make('Signal',[(0,.09,.9),(.125,.09,1),(.43,.09,.9),(.555,.14,1)],960,.2,.7)
make('Notice',[(0,.15,.87),(.24,.20,1)],780,.7,.35)
make('Tension',[(0,.10,.85),(.145,.10,.9),(.29,.10,.95),(.435,.14,1)],840,.3,.4)
make('Resolve',[(0,.18,1),(.31,.085,.8),(.445,.14,.95)],720,.9,.6)
make('GlassPulse',[(0,.085,.8),(.14,.085,.9),(.28,.14,1)],1160,.2,1)
