"""Layered, mono-compatible warning motifs; deterministic synthesis, no samples."""
import math, random, struct, wave, pathlib, subprocess
R=44100
ROOT=pathlib.Path(__file__).parent/'alerts'
ROOT.mkdir(exist_ok=True)

def design(name, events, base, texture, body, tail=0.10):
    duration=max(at+length for at,length,gain in events)+tail
    out=[0.0]*int(duration*R)
    rng=random.Random(41)
    for at,length,gain in events:
        phase=0.0; low=0.0; prev=0.0
        for j in range(int((length+tail)*R)):
            t=j/R
            # Fast but rounded attack; short, controlled release.
            env=min(1.0,t/.004)*math.exp(-2.4*t/length)
            if t>length: env*=math.exp(-60*(t-length))
            phase+=2*math.pi*base/R
            n=rng.uniform(-1,1); low+=.16*(n-low)
            band=low-prev; prev+=.025*(low-prev)
            core=math.sin(phase+texture*math.sin(phase*1.997)*math.exp(-35*t))
            tension=math.sin(phase*1.034)*.18
            impact=math.sin(2*math.pi*(180*t+2.3*(1-math.exp(-45*t))))*math.exp(-42*t)
            grain=band*math.exp(-55*t)
            # A quiet resonant layer gives weight without relying on sub-bass.
            weight=math.sin(phase*.5)*math.exp(-13*t)
            value=(.62*core+.16*tension+body*.28*impact+.22*texture*grain+.16*body*weight)*env*gain
            index=int(at*R)+j
            if index<len(out): out[index]+=value
    rms=math.sqrt(sum(v*v for v in out)/len(out)); peak=max(abs(v) for v in out)
    scale=min(.16/max(rms,1e-9),.68/max(peak,1e-9))
    samples=[round(v*scale*32767) for v in out]
    path=ROOT/(name+'.wav')
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(R)
        f.writeframes(struct.pack('<'+'h'*len(samples),*samples))
    subprocess.run(['afconvert','-f','AIFF','-d','BEI16',str(path),str(ROOT/(name+'.aiff'))],check=True)

# Repeated urgent cadence with a tactile onset and a weighted final beat.
design('Tripwire',[(0,.12,1),(.13,.12,.85),(.26,.12,1),(.55,.12,1),(.68,.12,.85),(.81,.20,1)],860,1.7,.8)
# Two sharp disruptions; the last pair is closer, without pitch swoops.
design('Interrupt',[(0,.18,1),(.23,.10,.8),(.64,.18,1),(.82,.10,.9)],760,2.4,.5)
# Clock-like precision, a deliberate pause, then a compressed final burst.
design('Watchdog',[(0,.085,1),(.17,.085,.85),(.34,.085,1),(.70,.085,1),(.81,.085,.85),(.92,.13,1)],970,.45,.35)
# Lower carrier with audible upper texture for small speakers.
design('Pressure',[(0,.17,.78),(.22,.17,.84),(.43,.17,.9),(.62,.17,.96),(.79,.24,1)],610,2.1,1.1)
# Small dry clicks layered with a narrow, tense tone; two distinct packets.
design('Relay',[(0,.08,1),(.10,.08,.8),(.20,.08,.9),(.56,.08,1),(.66,.08,.8),(.76,.12,1)],1120,3.1,.25)
# Strong opening pulse followed by a tighter response, no tune or siren.
design('Sentinel',[(0,.24,1),(.36,.10,.8),(.48,.10,.85),(.60,.10,.9),(.72,.17,1)],810,.9,1.0)
