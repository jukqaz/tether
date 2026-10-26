import React, { useState, useRef, useEffect } from 'react';
import { LinkIcon } from '@phosphor-icons/react/dist/csr/Link';
import { PowerIcon } from '@phosphor-icons/react/dist/csr/Power';
import { PlugIcon } from '@phosphor-icons/react/dist/csr/Plug';
import { GearSixIcon } from '@phosphor-icons/react/dist/csr/GearSix';
import { CaretRightIcon } from '@phosphor-icons/react/dist/csr/CaretRight';
import { CaretDownIcon } from '@phosphor-icons/react/dist/csr/CaretDown';
import { CheckIcon } from '@phosphor-icons/react/dist/csr/Check';
import { StopIcon } from '@phosphor-icons/react/dist/csr/Stop';
import { ShieldWarningIcon } from '@phosphor-icons/react/dist/csr/ShieldWarning';
import { ArrowCounterClockwiseIcon } from '@phosphor-icons/react/dist/csr/ArrowCounterClockwise';
import { SettingsContent } from './SettingsContent';
import { menuText, protectionCopy } from './menu-copy';
import { reconcilePreview } from './preview-state';
import { disconnectPreview, connectPreview } from './power-preview';
import './settings.css';

const INITIAL = {
  state:'manual', lid:true, screen:true, displayMode:'off', disconnect:'all', auto:true,
  batteryLimit:'120', reserve:'20', hot:true, lowPower:false, recovery:'manual',
  login:true, menuText:'icon', language:'ko', appearance:'light', endNotify:false, preNotify:false,
  channel:'stable', recording:false, sleepAction:'sleep', autoRest:false, logWindow:'60', reportWindow:'60',
  remaining:2700, batteryRemaining:6300, selectedDuration:30, power:'ac', untimed:false, stopRequested:false,
  updateState:'idle', autoCheck:true, currentVersion:'1.0.0', currentBuild:'100', availableVersion:'1.0.1', lastChecked:null,
};
const SCENARIOS = [['automatic','자동 유지'],['manual','수동 유지'],['stopped','모두 중지'],['protected','보호 중지']];
const POLICIES = [['all','모두 끝내기','자동과 타이머를 모두 종료'],['automatic','자동만 끝내기','배터리에서 허용된 수동 타이머는 계속'],['allowed','허용된 유지 계속','배터리에서 허용된 기존 작업만 계속']];
const TABS = [['keep','잠자기 방지',PowerIcon],['power','전원 동작',PlugIcon],['app','앱 설정',GearSixIcon]];
const statePower = state => state==='automatic'||state==='stopped'?'ac':'battery';
const labelFor = state => SCENARIOS.find(([key])=>key===state)?.[1] || '대기';
const formatTime = n => n>=3600?`${Math.floor(n/3600)}:${String(Math.floor(n%3600/60)).padStart(2,'0')}:00`:`${Math.floor(n/60)}:00`;
const endClock = (n,locale) => new Intl.DateTimeFormat(locale==='en'?'en-US':'ko-KR',{hour:'numeric',minute:'2-digit'}).format(new Date(2026,9,26,15,Math.floor(n/60)));

function Toggle({label,checked,onChange,disabled=false}) {
  return <button className="switch" type="button" role="switch" aria-checked={checked} aria-label={label} disabled={disabled} onClick={()=>onChange(!checked)}/>;
}

function Menu({model,onChange,onSettings,locale,instance='main'}) {
  const t = text => menuText(locale,text);
  const [policyOpen,setPolicyOpen]=useState(false);
  const [restOpen,setRestOpen]=useState(false);
  const [timeMore,setTimeMore]=useState(false);
  const root=useRef(null);
  const {state}=model;
  const protectedState=state==='protected', stopped=state==='stopped', manual=state==='manual', automatic=state==='automatic';
  const blocked=protectedState||stopped;
  const power=model.power||statePower(state);
  const autoActive=power==='ac'&&model.auto&&!model.autoRest;
  useEffect(()=>{
    const close=e=>{if(!root.current?.contains(e.target)){setPolicyOpen(false);setRestOpen(false);setTimeMore(false)}};
    const esc=e=>{if(e.key==='Escape'){setPolicyOpen(false);setRestOpen(false);setTimeMore(false)}};
    document.addEventListener('pointerdown',close);document.addEventListener('keydown',esc);
    return()=>{document.removeEventListener('pointerdown',close);document.removeEventListener('keydown',esc)};
  },[]);
  useEffect(()=>{setPolicyOpen(false);setRestOpen(false);setTimeMore(false)},[state]);
  const start=()=>{
    const limit=Number(model.batteryLimit)*60, duration=Number(model.selectedDuration)*60||0;
    onChange({untimed:power==='ac'&&model.selectedDuration==='untimed',remaining:power==='battery'?Math.min(duration,limit):duration,batteryRemaining:limit,state:'manual',lastPowerEvent:null});
  };
  const allow=()=>{if(!protectedState)onChange('state',autoActive?'automatic':'waiting')};
  const title=protectedState?'보호를 위해 중지했어요':stopped?'모두 중지됨':manual?(model.untimed?'직접 유지 중':autoActive?'자동 + 타이머 실행 중':'타이머 실행 중'):automatic?'자동 잠자기 방지 중':state==='unplugged'?'전원 분리로 종료':model.autoRest?'자동만 쉬는 중':'잠자기 방지 꺼짐';
  const protection=protectionCopy(locale,model.protectionSnapshot,model.reserve);
  const detail=protectedState?protection.reason:stopped?'다시 허용할 때까지 시작을 멈춥니다':power==='ac'?'전원 연결 중':'배터리 사용 중';
  const manualFooter=autoActive?'직접 시작한 유지가 끝나도 자동 유지는 계속됩니다.':model.autoRest?'자동은 잠시 쉬고 있어요.':model.auto?'자동은 전원 연결 대기 중':'자동 시작 꺼짐';
  return <section className={`mac-menu ${protectedState?'is-protected':''}`} data-testid={`menu-${instance}`} ref={root} aria-label={`${t(labelFor(state))} ${t('메뉴바 시안')}`}>
    <header className="menu-brand"><LinkIcon size={16} weight="bold"/><strong>Tether</strong><span className="power-source">{power==='ac'&&<PlugIcon size={12}/>} {t(power==='ac'?'전원 연결 중':'배터리 사용 중')}</span></header>
    <div className="menu-content">
      <div className="status-line">
        {protectedState?<ShieldWarningIcon size={19} weight="fill"/>:<span className={`status-dot ${automatic||manual?'active':''}`}/>}
        <div><h2>{t(title)}</h2>{blocked&&<p>{t(detail)}</p>}{protectedState&&protection.current&&<p>{protection.current}</p>}</div>
      </div>
      {model.lastPowerEvent==='unplugged'&&manual&&<p className="power-event-note" role="status">{t(model.state==='manual'?'전원을 뺐어요. 허용된 타이머만 계속합니다.':'전원 분리로 현재 작업을 끝냈어요.')}</p>}
      {manual?<div className="timer-section">
        <div className="timer-number" aria-label={t('타이머 남은 시간')}>{model.untimed?t('끄기 전까지'):formatTime(model.remaining)}</div>
        <div className="timer-end">{model.untimed?t('직접 끝낼 때까지 유지'):locale==='en'?`Ends at ${endClock(model.remaining,locale)}`:`${endClock(model.remaining,locale)}에 끝남`}</div>
        <div className={model.untimed?'one-action':'two-actions'}>
          {!model.untimed&&<button className="soft-button" disabled={power==='battery'&&model.remaining+1800>model.batteryRemaining} onClick={()=>onChange('remaining',model.remaining+1800)}>{t('30분 추가')}</button>}
          <button className="soft-button" onClick={()=>onChange('state',autoActive?'automatic':'waiting')}>{t(model.untimed?'유지 끝내기':'타이머 끝내기')}</button>
        </div>
        {!model.untimed&&power==='battery'&&model.remaining+1800>model.batteryRemaining&&<p className="explanation">{t('배터리 사용 한도 때문에 더 늘릴 수 없어요.')}</p>}
        {autoActive&&<p className="subtle">{t(manualFooter)}</p>}
      </div>:blocked?<div className="blocked-detail">
        <p>{t(protectedState?(power==='ac'?'충분히 충전한 뒤 보호 상태를 확인하세요.':'전원을 연결한 뒤 다시 확인하세요.'):'끝난 타이머는 다시 시작하지 않습니다.')}</p>
        {protectedState&&<button className="text-button" onClick={()=>onSettings('keep')}>{t('보호 설정 보기')}<CaretRightIcon size={12}/></button>}
      </div>:<div className="manual-start">
        <div className="section-label">{t('유지 시간')}</div>
        <div className="duration-row"><div className="segments" role="group" aria-label={t('유지 시간 선택')}>
          {[30,60,120].map(minutes=><button key={minutes} disabled={power==='battery'&&minutes>Number(model.batteryLimit)} aria-pressed={model.selectedDuration===minutes} onClick={()=>onChange('selectedDuration',minutes)}>{t(minutes===30?'30분':minutes===60?'1시간':'2시간')}</button>)}
        </div>{power==='ac'&&<div className="popup-anchor"><button className="icon-button more-time" aria-label={t('다른 유지 시간')} aria-expanded={timeMore} onClick={()=>setTimeMore(!timeMore)}><CaretDownIcon size={13}/></button>{timeMore&&<div className="native-popup time-popup" role="menu"><button role="menuitem" onClick={()=>{onChange('selectedDuration','untimed');setTimeMore(false)}}>{t('끄기 전까지')}</button></div>}</div>}</div>
        {model.selectedDuration==='untimed'&&<p className="subtle">{t('선택한 시간: 끄기 전까지')}</p>}
        <button className="primary-button" onClick={start}>{t('직접 시작')}</button>
      </div>}
      {model.auto&&(autoActive||model.autoRest)&&!blocked&&<div className="rest-wrap popup-anchor"><button className="menu-row" aria-haspopup={model.autoRest?undefined:'menu'} aria-expanded={restOpen} onClick={()=>model.autoRest?onChange('autoRest',false):setRestOpen(!restOpen)}><span>{t(model.autoRest?'자동 재개':'자동만 쉬기…')}</span><CaretRightIcon size={14}/></button>{restOpen&&<div className="native-popup" role="menu">{['30분','1시간','직접 재개할 때까지'].map(duration=><button role="menuitem" key={duration} onClick={()=>{onChange('autoRest',duration);setRestOpen(false)}}>{t(duration)}</button>)}</div>}</div>}
      {blocked?<div className="saved-options"><p>{t('덮개·화면 설정은 그대로 보관됩니다.')}</p></div>:<div className="quick-options">
        {!manual&&!automatic&&<p className="section-label">{t('다음 작업에 적용할 설정')}</p>}
        <div className="toggle-row"><span>{t('덮개 닫아도 계속 사용')}</span><Toggle label={t('덮개 닫아도 계속 사용')} checked={model.lid} onChange={value=>onChange('lid',value)}/></div>
        <div className="toggle-row"><span>{t('열린 동안 화면 켜두기')}</span><Toggle label={t('열린 동안 화면 켜두기')} checked={model.screen} onChange={value=>onChange('screen',value)}/></div>
      </div>}
      {!blocked&&<div className="popup-anchor policy-anchor"><button className="menu-row" aria-haspopup="menu" aria-expanded={policyOpen} aria-label={t('전원 분리 옵션')} onClick={()=>setPolicyOpen(!policyOpen)}><span>{t('전원을 빼면')}</span><span className="row-value">{t(POLICIES.find(([key])=>key===model.disconnect)?.[1])}<CaretRightIcon size={14}/></span></button>{policyOpen&&<div className="native-popup policy-popup" role="menu" aria-label={t('전원 분리 정책')}>{POLICIES.map(([key,label,description])=><button role="menuitemradio" aria-checked={model.disconnect===key} key={key} onClick={()=>{onChange('disconnect',key);setPolicyOpen(false)}}><span className="check-space">{model.disconnect===key&&<CheckIcon size={13} weight="bold"/>}</span><span><strong>{t(label)}</strong><small>{t(description)}</small></span></button>)}</div>}</div>}
    </div>
    <footer className="menu-footer"><button disabled={protectedState&&model.stopRequested} className={`footer-action ${stopped?'primary-button':''}`} onClick={stopped?allow:()=>protectedState?onChange('stopRequested',true):onChange('state','stopped')}>{stopped?<ArrowCounterClockwiseIcon size={14}/>:<StopIcon size={12} weight="fill"/>}{t(stopped?'다시 허용':protectedState&&model.stopRequested?'모두 중지됨':'모두 중지')}</button><button className="footer-settings" onClick={()=>onSettings('keep')}><GearSixIcon size={16}/>{t('설정…')}</button></footer>
  </section>;
}

function SettingsWindow({model,onChange,tab,onTab,expandAll,compact,locale}) {
  const t=text=>menuText(locale,text), scroll=useRef(null);
  useEffect(()=>{if(scroll.current)scroll.current.scrollTop=0},[tab,locale]);
  return <section className={`mac-window ${compact?'compact':''} tab-${tab}`} data-testid="settings-window" aria-label={`Tether ${t('설정 시안')}`}>
    <header className="settings-toolbar"><div className="traffic-lights" aria-hidden="true"><span/><span/><span/></div><div className="settings-tabs" role="tablist" aria-label={t('설정 탭')}>{TABS.map(([key,label,Icon])=><button key={key} role="tab" aria-selected={tab===key} aria-controls="settings-panel" onClick={()=>onTab(key)}><Icon size={22} weight="regular"/><span>{t(label)}</span></button>)}</div></header>
    <div className="settings-scroll" ref={scroll} data-testid="settings-scroll" id="settings-panel" role="tabpanel" aria-label={`${t(TABS.find(([key])=>key===tab)[1])} ${t('내용')}`} tabIndex={0}><SettingsContent model={model} onChange={onChange} tab={tab} expandAll={expandAll} locale={locale}/><div className="scroll-end-space" data-testid="settings-end"/></div>
  </section>;
}

export function App() {
  const [model,setModelRaw]=useState({...INITIAL}), [tab,setTab]=useState('power'), [view,setView]=useState('workspace');
  const setModel=change=>setModelRaw(old=>reconcilePreview(old,typeof change==='function'?change(old):change));
  const [pair,setPair]=useState('running'), [expandAll,setExpandAll]=useState(false), [compact,setCompact]=useState(true);
  const [systemDark,setSystemDark]=useState(()=>window.matchMedia('(prefers-color-scheme: dark)').matches);
  const [systemLanguage,setSystemLanguage]=useState(()=>navigator.language.startsWith('ko')?'ko':'en');
  const locale=model.language==='system'?systemLanguage:model.language;
  const theme=model.appearance==='system'?(systemDark?'dark':'light'):model.appearance;
  const t=text=>menuText(locale,text);
  useEffect(()=>{
    const media=window.matchMedia('(prefers-color-scheme: dark)'), listener=event=>setSystemDark(event.matches), languageListener=()=>setSystemLanguage(navigator.language.startsWith('ko')?'ko':'en');
    media.addEventListener('change',listener);window.addEventListener('languagechange',languageListener);
    return()=>{media.removeEventListener('change',listener);window.removeEventListener('languagechange',languageListener)};
  },[]);
  useEffect(()=>{document.documentElement.lang=locale;document.title=`Tether · ${t('상태·스크롤 시안')}`},[locale]);
  const update=(key,value)=>setModel(old=>{
    const next={...old,...(typeof key==='object'?key:{[key]:value})};
    if(key==='state'&&value!==old.state)next.lastPowerEvent=null;
    if(key==='batteryLimit'&&old.power==='battery')next.selectedDuration=Math.min(Number(old.selectedDuration)||30,Number(value));
    return next;
  });
  const scenarioModel=(state,old)=>{const seed={...old,state,power:state==='manual'?'ac':statePower(state),auto:state==='automatic'?true:old.auto,remaining:['stopped','protected'].includes(state)?0:2700,batteryRemaining:Number(old.batteryLimit)*60,selectedDuration:30,untimed:false,stopRequested:false,autoRest:false,lastPowerEvent:null,protectionSnapshot:state==='protected'?{battery:Math.max(0,Number(old.reserve)-2),threshold:Number(old.reserve)}:old.protectionSnapshot};return state==='unplugged'?disconnectPreview({...seed,state:'manual',power:'ac'}):seed};
  const setScenario=state=>setModel(old=>scenarioModel(state,old));
  const showSettings=key=>{setTab(key);setView('workspace')};
  return <main className="prototype" data-theme={theme} data-locale={locale}>
    <div className="wallpaper" aria-hidden="true"/>
    <header className="review-header"><div><strong>Tether</strong><span>{t('상태·스크롤 시안')}</span><small>{t('웹 시안 · 실제 Mac 설정에 영향 없음')}</small></div>
      <div className="preview-preferences">
        <label>{t('언어')}<select data-testid="review-language" value={model.language} onChange={event=>update('language',event.target.value)}><option value="system">{t('시스템 설정')}</option><option value="ko">한국어</option><option value="en">English</option></select></label>
        <label>{t('화면 모드')}<select data-testid="review-appearance" value={model.appearance} onChange={event=>update('appearance',event.target.value)}><option value="system">{t('시스템 설정')}</option><option value="light">{t('밝게')}</option><option value="dark">{t('어둡게')}</option></select></label>
      </div>
    </header>
    <nav className="review-controls" aria-label={t('시안 검수 도구')}>
      <div className="review-segments">{[['workspace','메뉴와 설정'],['compare','상태 비교']].map(([key,label])=><button key={key} aria-pressed={view===key} onClick={()=>setView(key)}>{t(label)}</button>)}</div>
      {view==='workspace'?<>
        <div className="review-segments states">{SCENARIOS.map(([key,label])=><button key={key} aria-pressed={model.state===key} onClick={()=>setScenario(key)}>{t(label)}</button>)}</div>
        <button type="button" className="preview-power-button" data-testid="review-power-event" onClick={()=>setModel(old=>old.power==='ac'?disconnectPreview(old):connectPreview(old))}>{t(model.power==='ac'?'전원 분리해 보기':'전원 연결해 보기')}</button>
        <label className="tool-check"><input type="checkbox" checked={expandAll} onChange={event=>setExpandAll(event.target.checked)}/>{t('상세 모두 펼침')}</label>
        <label className="tool-check"><input type="checkbox" checked={compact} onChange={event=>setCompact(event.target.checked)}/>{t('최소 창')}</label>
        {tab==='app'&&<label className="tool-check"><input type="checkbox" checked={Boolean(model.updatePrepareFail)} onChange={event=>update('updatePrepareFail',event.target.checked)}/>{t('준비 실패 예시')}</label>}
        {tab==='app'&&<label className="update-fixture">{t('업데이트 상태')}<select data-testid="review-update" value={model.updateState} onChange={event=>update({updateState:event.target.value,lastChecked:event.target.value==='current'||event.target.value==='available'?'2026-10-26T06:00:00Z':null})}>{[['idle','기본'],['checking','확인 중'],['current','최신'],['available','업데이트 있음'],['error','연결 실패']].map(([key,label])=><option value={key} key={key}>{t(label)}</option>)}</select></label>}
      </>:<div className="review-segments"><button aria-pressed={pair==='running'} onClick={()=>setPair('running')}>{t('수동 유지 · 전원 분리')}</button><button aria-pressed={pair==='blocked'} onClick={()=>setPair('blocked')}>{t('모두 중지 · 보호 중지')}</button></div>}
    </nav>
    {view==='workspace'?<div className="workspace"><div className="menu-stage"><Menu model={model} onChange={update} onSettings={showSettings} locale={locale}/></div><SettingsWindow model={model} onChange={update} tab={tab} onTab={setTab} expandAll={expandAll} compact={compact} locale={locale}/></div>:<div className="comparison-stage">{(pair==='running'?['manual','unplugged']:['stopped','protected']).map(state=>{
      const seed=scenarioModel(state,model);
      return <figure key={state}><figcaption>{t(state==='unplugged'?'전원 분리 후':labelFor(state))}</figcaption><Menu model={seed} locale={locale} onChange={(key,value)=>{setModel({...seed,...(typeof key==='object'?key:{[key]:value})});setView('workspace')}} onSettings={key=>{setModel(seed);showSettings(key)}} instance={state}/></figure>;
    })}</div>}
    <p className="review-note">{t('모든 상태·버전·수치는 예시입니다. 전원·잠금·도우미·업데이트를 제어하지 않습니다.')}</p>
  </main>;
}
