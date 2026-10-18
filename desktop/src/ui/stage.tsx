import { useEffect, useState } from 'preact/hooks';
import type { Persona } from '../content';

// The scene acted out, as on the iPhone: a backdrop for the place, the other person and you. Mouths move with the
// voice that is speaking; the characters blink, breathe and light up when it's their line.

export type Setting = 'site' | 'meetingRoom' | 'office' | 'evening';

export function settingFor(place: string): Setting {
  const p = place.toLowerCase();
  if (p.includes('pier') || p.includes('safety') || p.includes('site')) return 'site';
  if (p.includes('end of the day') || p.includes('evening') || p.includes('restaurant')) return 'evening';
  if (p.includes('office') || p.includes('desk') || p.includes('counter') || p.includes('phone')) return 'office';
  return 'meetingRoom';
}

interface Look {
  skin: string;
  hair: string;
  hairStyle: 'short' | 'bob' | 'long';
  jacket: string;
  shirt: string;
  tie?: string;
  glasses?: boolean;
  hardHat?: string;
}

const LOOKS: Record<string, Look> = {
  'p.sato': { skin: '#F0C8A4', hair: '#9C9C9C', hairStyle: 'short', jacket: '#2C3E5C', shirt: '#FFFFFF', tie: '#7A2E3A', glasses: true },
  'p.suzuki': { skin: '#F3CFB0', hair: '#3B2A20', hairStyle: 'bob', jacket: '#3C3C46', shirt: '#F4EDE4' },
  'p.takahashi': { skin: '#EBC29E', hair: '#1B1B1F', hairStyle: 'short', jacket: '#4A4F57', shirt: '#FFFFFF', tie: '#2D5DA8' },
  'p.ito': { skin: '#E0B48C', hair: '#1B1B1F', hairStyle: 'short', jacket: '#F28C28', shirt: '#2E3A4F', hardHat: '#F5C518' },
  'p.kobayashi': { skin: '#EFC7A2', hair: '#2A2420', hairStyle: 'short', jacket: '#6B4F3A', shirt: '#E8EEF4', glasses: true },
  'p.nakamura': { skin: '#F3D0B5', hair: '#5A3A28', hairStyle: 'long', jacket: '#8FB8DE', shirt: '#FFFFFF' },
  'p.yamada': { skin: '#EEC6A0', hair: '#4A4A4A', hairStyle: 'short', jacket: '#1F2A3C', shirt: '#FFFFFF', tie: '#8A1C2B', glasses: true },
  'p.mori': { skin: '#F5D3B8', hair: '#221A16', hairStyle: 'bob', jacket: '#2F3A4A', shirt: '#EAF0F6', glasses: true },
  'p.ogawa': { skin: '#F3D0B5', hair: '#6B4430', hairStyle: 'long', jacket: '#C9A27E', shirt: '#FFFFFF' },
  'p.inoue': { skin: '#E8BE98', hair: '#2B2B2B', hairStyle: 'short', jacket: '#3B3F46', shirt: '#DDE6F0', tie: '#2F6B4F' },
  'p.shimizu': { skin: '#EFC9A6', hair: '#161616', hairStyle: 'short', jacket: '#25282E', shirt: '#FFFFFF', tie: '#3A3A3A', glasses: true },
  'p.kimura': { skin: '#F6D6BE', hair: '#2E211A', hairStyle: 'bob', jacket: '#1E4D8C', shirt: '#FFFFFF' },
};

function partnerLook(persona: Persona | undefined, setting: Setting): Look {
  let look = persona && LOOKS[persona.id];
  if (!look) {
    look = persona?.voiceGender === 'female'
      ? { skin: '#F3CFB0', hair: '#3B2A20', hairStyle: 'bob', jacket: '#3C3C46', shirt: '#FFFFFF' }
      : { skin: '#EBC29E', hair: '#1B1B1F', hairStyle: 'short', jacket: '#3A4250', shirt: '#FFFFFF', tie: '#2D5DA8' };
  }
  return setting === 'site' && !look.hardHat ? { ...look, hardHat: '#FFFFFF' } : look;
}

function youLook(setting: Setting): Look {
  const look: Look = { skin: '#B07A52', hair: '#1E1A18', hairStyle: 'short', jacket: '#34495E', shirt: '#DCE8F5' };
  return setting === 'site' ? { ...look, hardHat: '#F5C518' } : look;
}

/** Seconds, redrawn about 30 times a second while the stage is on screen (not when motion is reduced). */
function useClock(): number {
  const [time, setTime] = useState(() => performance.now() / 1000);
  useEffect(() => {
    if (matchMedia('(prefers-reduced-motion: reduce)').matches) return;
    let frame = 0;
    let last = 0;
    const tick = (now: number) => {
      if (now - last > 33) {
        last = now;
        setTime(now / 1000);
      }
      frame = requestAnimationFrame(tick);
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, []);
  return time;
}

function Character(props: { look: Look; facesRight: boolean; talking: boolean; listening: boolean; time: number; x: number; active: boolean }) {
  const { look, talking, time } = props;
  const reduce = typeof matchMedia !== 'undefined' && matchMedia('(prefers-reduced-motion: reduce)').matches;
  const breathe = reduce ? 0 : Math.sin(time * 2) * 0.8;
  const bob = talking && !reduce ? Math.sin(time * 9) * 1.2 : 0;
  const shade = 'rgba(0,0,0,0.12)';
  let opening = 0;
  if (talking) opening = 0.15 + 0.85 * Math.abs(Math.sin(time * 13)) * (0.55 + 0.45 * Math.abs(Math.sin(time * 3.3)));
  else if (props.listening) opening = 0.1 + 0.3 * Math.abs(Math.sin(time * 6));
  const blinking = time % 3.7 < 0.13;
  const raise = talking ? Math.abs(Math.sin(time * 2.5)) * 1.2 : 0;
  const flip = props.facesRight ? '' : ' translate(100,0) scale(-1,1)';
  const mouthHeight = 2 + 8 * opening;

  return (
    <g transform={`translate(${props.x},120) scale(1.2)${flip}`}>
      {props.active && <ellipse cx="50" cy="150" rx="62" ry="36" fill="var(--signal)" opacity="0.28" filter="url(#glow)" />}
      <rect x="14" y={96 + breathe} width="72" height="64" rx="24" fill={look.jacket} />
      <polygon points={`40,${96 + breathe} 60,${96 + breathe} 50,${120 + breathe}`} fill={look.shirt} />
      {look.tie && (
        <polygon points={`50,${99 + breathe} 54,${106 + breathe} 50,${126 + breathe} 46,${106 + breathe}`} fill={look.tie} />
      )}
      <rect x="43" y="80" width="14" height="20" fill={look.skin} />
      <rect x="43" y="80" width="14" height="8" fill={shade} />
      <g transform={`translate(0,${bob})`}>
        {look.hairStyle !== 'short' && !look.hardHat && (
          <rect x="20" y="22" width="58" height={look.hairStyle === 'long' ? 82 : 64} rx="24" fill={look.hair} />
        )}
        <ellipse cx="50" cy="54" rx="26" ry="30" fill={look.skin} />
        <ellipse cx="25.5" cy="58" rx="4.5" ry="6" fill={look.skin} />
        <ellipse cx="25.5" cy="58" rx="2" ry="3" fill={shade} />
        {!look.hardHat
          ? <path d="M23 58 C19 32 32 20 50 20 C68 20 80 30 78 48 Q48 34 23 58 Z" fill={look.hair} />
          : <rect x="23" y="42" width="9" height="16" rx="3" fill={look.hair} />}
        {[55, 69].map((x) => (
          <g key={x}>
            {blinking
              ? <rect x={x - 3} y="57" width="6" height="1.5" rx="0.75" fill="#1f1f1f" />
              : <>
                  <ellipse cx={x} cy="56.8" rx="2.6" ry="3.3" fill="#1f1f1f" />
                  <circle cx={x + 0.5} cy="55.4" r="0.9" fill="#fff" />
                </>}
            <rect x={x - 4} y={47 - raise} width="8" height="2" rx="1" fill={look.hair} />
            {look.glasses && <ellipse cx={x} cy="56.5" rx="6" ry="5.5" fill="none" stroke="#333" stroke-width="1.3" />}
          </g>
        ))}
        {look.glasses && <path d="M61 56 L63 56 M49 56 L29 55" stroke="#333" stroke-width="1.3" />}
        <path d="M73 59 Q77 64 71 66" fill="none" stroke={shade} stroke-width="1.4" />
        <ellipse cx="69.5" cy="65.5" rx="4.5" ry="2.5" fill="rgba(255,105,140,0.22)" />
        {opening < 0.08
          ? <path d="M58 71.5 Q63 75 68 71.5" fill="none" stroke="#73262B" stroke-width="1.6" />
          : <ellipse cx="63.25" cy="72" rx="4.75" ry={mouthHeight / 2} fill="#6B1F26" />}
        {look.hardHat && (
          <>
            <path d="M21 43 C21 9 79 9 79 43 Z" fill={look.hardHat} />
            <rect x="46" y="15" width="9" height="27" rx="4.5" fill="rgba(255,255,255,0.35)" />
            <rect x="17" y="40" width="72" height="7" rx="3.5" fill={look.hardHat} />
            <rect x="17" y="44" width="72" height="3" rx="1.5" fill={shade} />
          </>
        )}
      </g>
    </g>
  );
}

function Backdrop(props: { setting: Setting }) {
  const W = 800;
  const H = 320;
  switch (props.setting) {
    case 'site':
      return (
        <g>
          <defs>
            <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#8EC5F0" /><stop offset="0.65" stop-color="#E3F1FC" />
            </linearGradient>
          </defs>
          <rect width={W} height={H} fill="url(#sky)" />
          <rect x="0" y={H * 0.40} width={W} height={H * 0.05} fill="#B9C2CC" />
          {[0, 1, 2, 3, 4, 5].map((i) => <rect key={i} x={W * (0.06 + i * 0.18)} y={H * 0.45} width={W * 0.035} height={H * 0.22} fill="#A6AFBA" />)}
          <rect x={W * 0.84} y={H * 0.10} width={W * 0.014} height={H * 0.58} fill="#E0A100" />
          <rect x={W * 0.62} y={H * 0.10} width={W * 0.34} height={H * 0.012} fill="#E0A100" />
          <line x1={W * 0.66} y1={H * 0.11} x2={W * 0.66} y2={H * 0.30} stroke="#5A5A5A" />
          <rect x="0" y={H * 0.66} width={W} height={H * 0.34} fill="#B8A88E" />
          {[0.43, 0.52].map((x) => <polygon key={x} points={`${W * x},${H * 0.98} ${W * (x + 0.035)},${H * 0.98} ${W * (x + 0.0175)},${H * 0.86}`} fill="#F07A1A" />)}
        </g>
      );
    case 'evening': {
      const buildings: [number, number, number][] = [[0, 0.30, 0.16], [0.15, 0.20, 0.14], [0.66, 0.26, 0.14], [0.80, 0.16, 0.20]];
      const windows: { x: number; y: number; lit: boolean }[] = [];
      for (const [x, top, width] of buildings) {
        for (let row = top + 0.05; row < 0.62; row += 0.07) {
          for (let column = x + 0.02; column < x + width - 0.03; column += 0.04) {
            windows.push({ x: column, y: row, lit: Math.floor((column + row) * 100) % 3 !== 0 });
          }
        }
      }
      return (
        <g>
          <defs>
            <linearGradient id="dusk" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0" stop-color="#2E3B5E" /><stop offset="0.35" stop-color="#6D597A" /><stop offset="0.7" stop-color="#E88D67" />
            </linearGradient>
          </defs>
          <rect width={W} height={H} fill="url(#dusk)" />
          {buildings.map(([x, top, width]) => <rect key={x} x={W * x} y={H * top} width={W * width} height={H * (0.70 - top)} fill="#22223B" />)}
          {windows.map((w, i) => <rect key={i} x={W * w.x} y={H * w.y} width={W * 0.022} height={H * 0.03} fill={w.lit ? '#FFD27D' : '#3A3A55'} />)}
          {[0.36, 0.50, 0.64].map((x) => (
            <g key={x}>
              <ellipse cx={W * x} cy={H * 0.14} rx={W * 0.05} ry={H * 0.09} fill="#FF6B4A" opacity="0.25" />
              <ellipse cx={W * x} cy={H * 0.14} rx={W * 0.03} ry={H * 0.06} fill="#D62828" />
            </g>
          ))}
          <rect x="0" y={H * 0.70} width={W} height={H * 0.30} fill="#4A3F4F" />
        </g>
      );
    }
    case 'office':
      return (
        <g>
          <defs>
            <linearGradient id="light" x1="0" y1="0" x2="1" y2="1">
              <stop offset="0" stop-color="#FFF4D6" /><stop offset="1" stop-color="#CFE6F7" />
            </linearGradient>
          </defs>
          <rect width={W} height={H} fill="#F2EEE6" />
          <rect x={W * 0.28} y={H * 0.06} width={W * 0.44} height={H * 0.40} fill="url(#light)" stroke="#CFC8BA" stroke-width="3" />
          <rect x={W * 0.88} y={H * 0.48} width={W * 0.07} height={H * 0.12} fill="#9C6B4A" />
          {[[0.86, 0.36], [0.91, 0.32], [0.95, 0.38], [0.90, 0.42]].map(([x, y]) => (
            <ellipse key={`${x}${y}`} cx={W * x} cy={H * y} rx={W * 0.04} ry={H * 0.06} fill="#5E9C5A" />
          ))}
          <rect x="0" y={H * 0.62} width={W} height={H * 0.38} fill="#E2DBCD" />
        </g>
      );
    default:
      return (
        <g>
          <rect width={W} height={H} fill="#E9E4DA" />
          <rect x={W * 0.04} y={H * 0.08} width={W * 0.22} height={H * 0.42} fill="#BFDDF2" stroke="#C9C2B4" stroke-width="3" />
          <rect x={W * 0.148} y={H * 0.08} width={W * 0.006} height={H * 0.42} fill="#C9C2B4" />
          <rect x={W * 0.34} y={H * 0.07} width={W * 0.40} height={H * 0.36} fill="#FFFFFF" stroke="#A9A39A" stroke-width="2" />
          {['#2D5DA8', '#2D5DA8', '#C0392B'].map((color, i) => (
            <rect key={i} x={W * 0.38} y={H * (0.14 + i * 0.08)} width={W * (0.12 + i * 0.06)} height={H * 0.018} fill={color} />
          ))}
          <rect x="0" y={H * 0.62} width={W} height={H * 0.38} fill="#D8D1C4" />
        </g>
      );
  }
}

export interface StageProps {
  persona: Persona | undefined;
  place: string;
  /** Who is speaking now. */
  otherTalking: boolean;
  learnerTalking: boolean;
  yourTurn: boolean;
  /** You play the colleague: you speak for the character on the left. */
  swapped: boolean;
  otherBubble: preact.ComponentChildren;
  learnerBubble: preact.ComponentChildren;
}

export function Stage(props: StageProps) {
  const time = useClock();
  const setting = settingFor(props.place);
  const { swapped, otherTalking, learnerTalking, yourTurn } = props;
  const leftTalking = swapped ? learnerTalking : otherTalking;
  const rightTalking = swapped ? otherTalking : learnerTalking;
  const leftActive = swapped ? learnerTalking || yourTurn : otherTalking;
  const rightActive = swapped ? otherTalking : learnerTalking || yourTurn;
  const colleague = props.persona?.nameEn || 'Colleague';
  const table = setting === 'meetingRoom' || setting === 'office';
  return (
    <div class="stage" role="img" aria-label={`The scene, ${props.place}`}>
      <svg viewBox="0 0 800 320" preserveAspectRatio="xMidYMax slice" class="stage-svg" aria-hidden="true">
        <defs>
          <filter id="glow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="14" /></filter>
        </defs>
        <Backdrop setting={setting} />
        <Character look={partnerLook(props.persona, setting)} facesRight talking={leftTalking}
                   listening={swapped && yourTurn} time={time} x={70} active={leftActive} />
        <Character look={youLook(setting)} facesRight={false} talking={rightTalking}
                   listening={!swapped && yourTurn} time={time + 1.7} x={610} active={rightActive} />
        {table && (
          <g>
            <rect x="0" y="292" width="800" height="5" fill={setting === 'office' ? '#C9B79C' : '#9C7B5B'} />
            <rect x="0" y="297" width="800" height="23" fill={setting === 'office' ? '#B59F80' : '#7E6045'} />
          </g>
        )}
      </svg>
      <div class="bubbles">
        <div class="bubble-slot left">{swapped ? props.learnerBubble : props.otherBubble}</div>
        <div class="bubble-slot right">{swapped ? props.otherBubble : props.learnerBubble}</div>
      </div>
      <div class="name-tags">
        <span class="name-tag">{swapped ? `${colleague} · you${yourTurn ? ', your turn' : ''}` : colleague}</span>
        <span class="name-tag">{swapped ? 'Your usual part' : yourTurn ? 'You · your turn' : 'You'}</span>
      </div>
    </div>
  );
}
