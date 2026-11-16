"""Fuller Focus derivatives: layered warning motifs without melodic sweeps."""
import math,pathlib,struct,subprocess,wave
R=44100
ROOT=pathlib.Path(__file__).parent/'alerts'
def design(name,events,body,edge,resonance,tail):
    out=[0.0]*int((max(t+d for t,d,g in events)+tail)*R)
    for at,d,g in events:
        for i in range(int((d+tail)*R)):
            t=i/R
            attack=math.sin(min(1,t/.008)*math.pi/2)**2
            env=attack*math.exp(-t/(d*.72))
            if t>d:env*=math.exp(-(t-d)/.055)
            p=2*math.pi*880*t
            # Focus's fundamental, with a low midrange body and a brief bright edge.
            core=math.sin(p)+body*.34*math.sin(p*.5)
            core+=body*.16*math.sin(p*.25)
            core+=edge*.15*math.sin(p*3)*math.exp(-t/.035)
            core+=.10*math.sin(p*2)*math.exp(-t/.10)
            # A short, quiet inharmonic resonance adds weight and tension.
            ring=resonance*.12*math.sin(p*1.4142)*math.exp(-t/.15)
            v=(core+ring)*env*g
            k=int(at*R)+i
            if k<len(out):out[k]+=v
    rms=math.sqrt(sum(v*v for v in out)/len(out));peak=max(map(abs,out))
    scale=min(.62/peak,.145/rms)
    samples=[round(v*scale*32767) for v in out]
    path=ROOT/(name+'.wav')
    with wave.open(str(path),'wb') as f:
        f.setnchannels(1);f.setsampwidth(2);f.setframerate(R)
        f.writeframes(struct.pack('<'+'h'*len(samples),*samples))
    subprocess.run(['afconvert','-f','AIFF','-d','BEI16',str(path),str(ROOT/(name+'.aiff'))],check=True)
design('FocusDepth',[(0,.17,.85),(.22,.17,.93),(.44,.28,1)],1.4,.5,.25,.2)
design('FocusPriority',[(0,.22,1),(.34,.12,.82),(.51,.12,.9),(.68,.28,1)],1.1,.8,.6,.22)
design('FocusCritical',[(0,.12,.85),(.17,.12,.92),(.34,.18,1),(.78,.12,.92),(.95,.12,.96),(1.12,.30,1)],1.2,.7,.45,.22)
design('FocusImpact',[(0,.30,1),(.45,.12,.86),(.62,.12,.91),(.79,.25,1)],1.7,.9,.8,.23)
design('FocusInsistent',[(0,.14,.84),(.22,.14,.88),(.42,.14,.92),(.60,.14,.96),(.76,.27,1)],1.05,.5,.35,.20)
