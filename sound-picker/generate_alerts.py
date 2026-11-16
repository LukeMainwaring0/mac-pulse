"""Generate short, peak-limited warning sounds, with click-free envelopes."""
import math, pathlib, struct, subprocess, wave
ROOT = pathlib.Path(__file__).parent / 'alerts'
ROOT.mkdir(exist_ok=True)
RATE = 44100

def make(name, pulses):
    samples = []
    for duration, start, end, rough in pulses:
        n = int(duration * RATE)
        for i in range(n):
            t = i / RATE
            if not start:
                samples.append(0); continue
            phase = 2 * math.pi * (start*t + (end-start)*t*t/(2*duration))
            envelope = min(1, t/.012, (duration-t)/.045)
            tone = (math.sin(phase) + rough*.3*math.sin(phase*1.06) + .2*math.sin(2*phase)) / (1.2+rough*.3)
            samples.append(int(0.65 * 32767 * envelope * tone))
    wav = ROOT/(name+'.wav')
    with wave.open(str(wav),'wb') as f:
        f.setnchannels(1); f.setsampwidth(2); f.setframerate(RATE)
        f.writeframes(struct.pack('<'+'h'*len(samples), *samples))
    subprocess.run(['afconvert','-f','AIFF','-d','BEI16',str(wav),str(ROOT/(name+'.aiff'))],check=True)

def beep(f,d=.16,r=0): return (d,f,f,r)
def gap(d=.1): return (d,0,0,0)
make('Warning', [beep(880),gap(),beep(660),gap(.25),beep(880),gap(),beep(660)])
make('Fault', [beep(420,.22,1),gap(.12),beep(340,.36,1)])
make('Critical', [beep(1000,.12),gap(.08),beep(1000,.12),gap(.08),beep(1000,.12),gap(.3)]*2)
make('Siren', [(0.45,520,1050,0),(0.45,1050,520,0)]*2)
make('DoubleAlarm', [beep(740,.25,1),gap(.12),beep(740,.25,1),gap(.3),beep(550,.4,1)])
make('SystemError', [beep(740,.16),gap(.06),beep(554,.2),gap(.06),beep(370,.45,1)])
make('UrgentPulse', [beep(820,.09,1),gap(.07)]*6)
make('DeepWarning', [beep(260,.28,1),gap(.16),beep(310,.28,1),gap(.16),beep(260,.45,1)])
# Variations of Urgent Pulse: fixed pitch, clipped pulses, no melodic contour.
make('PulseTight', [beep(820,.075,1),gap(.045)]*8)
make('PulseLower', [beep(620,.09,1),gap(.07)]*6)
make('PulseSharper', [beep(1080,.09,1),gap(.07)]*6)
make('PulseDry', [beep(820,.07,0),gap(.075)]*7)
make('PulseGrit', [beep(820,.105,2),gap(.06)]*6)
make('PulseTriplets', ([beep(820,.09,1),gap(.065)]*3+[gap(.22)])*2)
make('PulseInsistent', [beep(820,.14,1),gap(.085)]*6)
make('PulseAccelerating', sum(([beep(820,.09,1),gap(g)] for g in [.16,.13,.1,.08,.06,.045,.045]), []))
