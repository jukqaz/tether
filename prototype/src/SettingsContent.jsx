import { useEffect, useId, useRef, useState } from 'react';
import { CaretRightIcon } from '@phosphor-icons/react/dist/csr/CaretRight';
import { ArrowClockwiseIcon } from '@phosphor-icons/react/dist/csr/ArrowClockwise';
import { CircleNotchIcon } from '@phosphor-icons/react/dist/csr/CircleNotch';
import { CheckCircleIcon } from '@phosphor-icons/react/dist/csr/CheckCircle';
import { ArrowCircleDownIcon } from '@phosphor-icons/react/dist/csr/ArrowCircleDown';
import { WarningCircleIcon } from '@phosphor-icons/react/dist/csr/WarningCircle';
import { settingsCopy } from './settings-copy';
import './settings.css';

function Section({ title, children, footer }) {
  return (
    <section className="s-section" aria-label={title}>
      <h2 className="s-section-title">{title}</h2>
      {children}
      {footer && <p className="s-footer">{footer}</p>}
    </section>
  );
}

function ToggleRow({ label, checked, onChange, disabled = false, description }) {
  return (
    <label className={`s-row s-toggle-row${disabled ? ' s-disabled' : ''}`}>
      <span className="s-row-copy">
        <span>{label}</span>
        {description && <span className="s-row-description">{description}</span>}
      </span>
      <span className="s-toggle">
        <input type="checkbox" checked={Boolean(checked)} onChange={(event) => onChange(event.target.checked)} disabled={disabled} />
        <span className="s-switch" aria-hidden="true" />
      </span>
    </label>
  );
}

function SelectRow({ label, value, onChange, options, disabled = false }) {
  return (
    <label className={`s-row s-select-row${disabled ? ' s-disabled' : ''}`}>
      <span>{label}</span>
      <select value={value} onChange={(event) => onChange(event.target.value)} disabled={disabled}>
        {options.map(([optionValue, optionLabel]) => <option key={optionValue} value={optionValue}>{optionLabel}</option>)}
      </select>
    </label>
  );
}

function Disclosure({ title, expandAll, children }) {
  const [open, setOpen] = useState(false);
  return (
    <details className="s-disclosure" open={Boolean(expandAll || open)} onToggle={(event) => { if (!expandAll) setOpen(event.currentTarget.open); }}>
      <summary onClick={(event) => { if (expandAll) event.preventDefault(); }}>
        <span>{title}</span>
        <CaretRightIcon size={12} weight="bold" aria-hidden="true" />
      </summary>
      <div className="s-detail-body">{children}</div>
    </details>
  );
}

function EmptyExample({ children }) {
  return <div className="s-empty-example"><p>{children}</p></div>;
}

function UpdateCard({ model, onChange, copy: c, locale }) {
  const [notice, setNotice] = useState('');
  const blockerId = useId();
  const confirmationId = useId();
  const change = useRef(onChange);
  change.current = onChange;
  const state = model.updateState ?? 'idle';
  const preparation = model.updatePreparation ?? 'idle';
  const version = model.currentVersion ?? '1.0.0';
  const build = model.currentBuild ?? '100';
  const availableVersion = model.availableVersion ?? '1.0.1';
  const checking = state === 'checking';
  const available = state === 'available';
  const power = model.power ?? (model.state === 'automatic' || model.state === 'stopped' ? 'ac' : 'battery');
  const protectedState = model.state === 'protected';
  const active = model.state === 'manual' || model.state === 'automatic';
  const blocked = protectedState || power !== 'ac';
  const blocker = protectedState ? c.protectionBlock : power !== 'ac' ? c.batteryBlock : '';
  const context = useRef({ power, protectedState, channel: model.channel, version, availableVersion });
  const phases = ['confirm', 'preparing', 'ready', 'error'];
  const hasPreparation = available && phases.includes(preparation) && (preparation === 'confirm' || (model.state === 'stopped' && !model.recording));
  const states = {
    idle: [ArrowClockwiseIcon, c.idleTitle, c.idleDetail],
    checking: [CircleNotchIcon, c.checkingTitle, c.checkingDetail],
    current: [CheckCircleIcon, c.currentTitle, c.currentDetail(version)],
    available: [ArrowCircleDownIcon, c.availableTitle(availableVersion), c.availableDetail],
    error: [WarningCircleIcon, c.errorTitle, c.errorDetail],
  };
  const [StatusIcon, title, detail] = states[state] ?? states.idle;
  const lastCheckedDate = model.lastChecked == null ? null : new Date(model.lastChecked);
  const lastChecked = lastCheckedDate && !Number.isNaN(lastCheckedDate.getTime())
    ? new Intl.DateTimeFormat(locale === 'en' ? 'en-US' : 'ko-KR', { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }).format(lastCheckedDate)
    : c.notChecked;

  useEffect(() => {
    if (!checking) return undefined;
    const timer = setTimeout(() => change.current({ updateState: 'available', lastChecked: Date.now(), updatePreparation: 'idle' }), 900);
    return () => clearTimeout(timer);
  }, [checking, model.channel]);

  useEffect(() => {
    const previous = context.current;
    const safetyChanged = previous.power !== power || previous.protectedState !== protectedState;
    const releaseChanged = previous.channel !== model.channel || previous.version !== version || previous.availableVersion !== availableVersion;
    const sessionRestarted = ['preparing', 'ready', 'error'].includes(preparation) && (model.state !== 'stopped' || Boolean(model.recording));
    context.current = { power, protectedState, channel: model.channel, version, availableVersion };
    if (preparation !== 'idle' && (safetyChanged || releaseChanged || !available || sessionRestarted || blocker)) {
      change.current('updatePreparation', 'idle');
      setNotice(safetyChanged || blocker ? 'safety' : sessionRestarted ? 'session' : '');
    }
  }, [power, protectedState, model.channel, version, availableVersion, available, model.state, model.recording, preparation, blocked]);

  useEffect(() => {
    if (preparation !== 'preparing' || !available || blocker || model.state !== 'stopped') return undefined;
    const timer = setTimeout(() => {
      const current = context.current;
      if (current.power === 'ac' && !current.protectedState) change.current('updatePreparation', model.updatePrepareFail ? 'error' : 'ready');
    }, 1200);
    return () => clearTimeout(timer);
  }, [preparation, available, blocked, model.state, model.updatePrepareFail]);

  const commitChannel = (value) => {
    change.current({ returningToStable: model.channel === 'beta' && value === 'stable', channel: value, updateState: 'idle', lastChecked: null, updateChannelConfirm: false, updatePreparation: 'idle' });
    setNotice('');
  };
  const changeChannel = (value) => {
    if (value === 'beta' && model.channel !== 'beta') change.current({ updateChannelConfirm: true, updatePreparation: 'idle' });
    else commitChannel(value);
  };
  const check = () => {
    setNotice('');
    change.current({ updateState: 'checking', updatePreparation: 'idle' });
  };
  const openConfirmation = () => {
    if (blocker || !available || model.updateChannelConfirm) return;
    setNotice('');
    change.current('updatePreparation', 'confirm');
  };
  const confirmPreparation = () => {
    if (blocker || !available || preparation !== 'confirm') return;
    setNotice('');
    change.current({ state: 'stopped', recording: false, remaining: 0, untimed: false, stopRequested: false, updatePreparation: 'preparing' });
  };
  const cancelPreparation = () => {
    setNotice(preparation === 'confirm' ? '' : 'cancelled');
    change.current('updatePreparation', 'idle');
  };
  const noticeText = notice === 'safety' ? c.safetyInvalidated : notice === 'session' ? c.sessionInvalidated : notice === 'cancelled' ? c.preparationCancelled : '';

  return (
    <div className="s-update-card">
      <SelectRow label={c.updateChannel} value={model.channel} onChange={changeChannel} options={c.channelOptions} disabled={checking || preparation === 'preparing'} />
      <ToggleRow label={c.autoCheck} checked={model.autoCheck ?? true} onChange={(value) => onChange('autoCheck', value)} />
      {model.channel === 'stable' && model.returningToStable && <p className="s-update-channel-note">{c.stableWait}</p>}
      {model.updateChannelConfirm && (
        <div className="s-channel-confirm">
          <strong>{c.betaConfirmTitle}</strong>
          <p>{c.betaConfirmDetail}</p>
          <div className="s-update-actions">
            <button type="button" className="s-button" onClick={() => onChange('updateChannelConfirm', false)} disabled={checking}>{c.cancel}</button>
            <button type="button" className="s-button" onClick={() => commitChannel('beta')} disabled={checking}>{c.confirmBeta}</button>
          </div>
        </div>
      )}
      <div className={`s-update-status s-update-${state}`} role="status" aria-live="polite" aria-busy={checking}>
        <StatusIcon size={20} className={checking ? 's-update-spinner' : undefined} aria-hidden="true" />
        <div><h3>{title}</h3><p>{detail}</p></div>
      </div>
      <dl className="s-update-metadata">
        <div><dt>{c.currentVersion}</dt><dd>{c.versionBuild(version, build)}</dd></div>
        <div><dt>{c.lastChecked}</dt><dd>{lastChecked}</dd></div>
      </dl>
      {available && blocker && <p className="s-update-blocker" id={blockerId}>{blocker}</p>}
      {noticeText && <p className="s-update-notice" role="status">{noticeText}</p>}
      {hasPreparation && !blocker && (
        <div className={`s-update-preparation s-preparation-${preparation}`} role="region" aria-labelledby={confirmationId} aria-live="polite" aria-busy={preparation === 'preparing'}>
          <div className="s-preparation-heading">
            {preparation === 'preparing' && <CircleNotchIcon size={16} className="s-update-spinner" aria-hidden="true" />}
            {preparation === 'ready' && <CheckCircleIcon size={16} aria-hidden="true" />}
            {preparation === 'error' && <WarningCircleIcon size={16} aria-hidden="true" />}
            <h4 id={confirmationId}>{preparation === 'confirm' ? c.preparationTitle : preparation === 'preparing' ? c.preparingTitle : preparation === 'ready' ? c.readyTitle : c.preparationErrorTitle}</h4>
          </div>
          {preparation === 'confirm' ? (
            <>
              <dl className="s-update-version-change">
                <div><dt>{c.fromVersion}</dt><dd>{version}</dd></div>
                <div><dt>{c.toVersion}</dt><dd>{availableVersion}</dd></div>
              </dl>
              <div className="s-update-summary"><h5>{c.changeSummary}</h5><ul>{c.releaseChanges.map((item) => <li key={item}>{item}</li>)}</ul></div>
              <div className="s-update-impact"><h5>{c.preparationImpact}</h5><ul>
                <li>{active ? c.endSessionImpact : c.noSessionImpact}</li>
                <li>{model.recording ? c.endRecordingImpact : c.noRecordingImpact}</li>
                <li>{c.restartImpact}</li>
              </ul></div>
              <div className="s-update-actions">
                <button type="button" className="s-button" onClick={cancelPreparation}>{c.cancel}</button>
                <button type="button" className="s-button s-confirm-button" onClick={confirmPreparation}>{active ? c.endAndPrepare : c.continuePreparation}</button>
              </div>
            </>
          ) : (
            <>
              <p>{preparation === 'preparing' ? c.preparingDetail : preparation === 'ready' ? c.readyDetail : c.preparationErrorDetail}</p>
              <p className="s-preparation-retention">{c.noSessionRevival}</p>
              <div className="s-update-actions">
                <button type="button" className="s-button" onClick={cancelPreparation}>{preparation === 'ready' ? c.closePreparation : c.cancel}</button>
                {preparation === 'error' && <button type="button" className="s-button" onClick={openConfirmation}>{c.retryPreparation}</button>}
              </div>
            </>
          )}
        </div>
      )}
      {!hasPreparation && (
        <div className="s-update-actions">
          {checking && <button type="button" className="s-button s-secondary-button" onClick={() => onChange('updateState', 'idle')}>{c.cancel}</button>}
          {available && <button type="button" className="s-button s-secondary-button" onClick={check} disabled={Boolean(model.updateChannelConfirm)}>{c.checkAgain}</button>}
          {available
            ? <button type="button" className="s-button" disabled={Boolean(blocker || model.updateChannelConfirm)} aria-describedby={blocker ? blockerId : undefined} onClick={openConfirmation}>{c.prepareUpdate}</button>
            : <button type="button" className="s-button" disabled={checking || Boolean(model.updateChannelConfirm)} onClick={check}>{checking ? c.checking : state === 'error' ? c.retry : state === 'current' ? c.checkAgain : c.checkUpdates}</button>}
        </div>
      )}
    </div>
  );
}

export function SettingsContent({ tab, model, onChange, expandAll = false, locale = 'ko' }) {
  const displayModeName = useId();
  const [restOpen, setRestOpen] = useState(false);
  const resolvedLocale = locale === 'en' ? 'en' : 'ko';
  const c = settingsCopy[resolvedLocale];
  const automaticFooter = !model.auto ? c.autoOff
    : model.state === 'protected' ? c.autoProtected
      : model.state === 'stopped' ? c.autoStopped
        : model.autoRest ? c.autoPaused(model.autoRest) : c.autoOn;
  const durationOptions = (values) => values.map((value) => [String(value), c.durations[value]]);

  return (
    <div className={`settings-content settings-content-${tab}`} data-locale={resolvedLocale} lang={resolvedLocale}>
      {tab === 'keep' && (
        <>
          <Section title={c.lidScreen} footer={c.lockFooter}>
            <div className="s-group">
              <ToggleRow label={c.lid} checked={model.lid} onChange={(value) => onChange('lid', value)} />
              <fieldset className="s-display-options" disabled={!model.lid}>
                <legend>{c.closedDisplay}</legend>
                <div className="s-segmented-control">
                  {c.displayOptions.map(([value, label]) => (
                    <label key={value}>
                      <input type="radio" name={displayModeName} value={value} checked={model.displayMode === value} onChange={() => onChange('displayMode', value)} />
                      <span>{label}</span>
                    </label>
                  ))}
                </div>
              </fieldset>
              <ToggleRow label={c.screen} checked={model.screen} onChange={(value) => onChange('screen', value)} />
            </div>
          </Section>
          <Section title={c.batteryUse} footer={c.batteryFooter}>
            <div className="s-group">
              <SelectRow label={c.batteryLimit} value={model.batteryLimit} onChange={(value) => onChange('batteryLimit', value)} options={durationOptions([30, 60, 120, 240])} />
            </div>
          </Section>
          <Section title={c.protection} footer={c.criticalHeat}>
            <div className="s-group">
              <Disclosure title={c.protectionDetails} expandAll={expandAll}>
                <SelectRow label={c.reserve} value={model.reserve} onChange={(value) => onChange('reserve', value)} options={['10', '20', '30'].map((value) => [value, `${value}%`])} />
                <ToggleRow label={c.hot} checked={model.hot} onChange={(value) => onChange('hot', value)} />
                <ToggleRow label={c.lowPower} checked={model.lowPower} onChange={(value) => onChange('lowPower', value)} />
                <SelectRow label={c.recovery} value={model.recovery} onChange={(value) => onChange('recovery', value)} options={c.recoveryOptions} />
                <p className="s-detail-note">{c.recoveryNote}</p>
              </Disclosure>
            </div>
          </Section>
        </>
      )}
      {tab === 'power' && (
        <>
          <Section title={c.pluggedIn} footer={automaticFooter}>
            <div className="s-group">
              <ToggleRow label={c.auto} checked={model.auto} onChange={(value) => onChange('auto', value)} />
              <div className="s-row s-rest-row" onBlur={(event) => { if (!event.currentTarget.contains(event.relatedTarget)) setRestOpen(false); }} onKeyDown={(event) => { if (event.key === 'Escape') setRestOpen(false); }}>
                <span>{c.automaticSession}</span>
                <button type="button" className="s-button" disabled={!model.auto && !model.autoRest} aria-haspopup={model.autoRest ? undefined : 'menu'} aria-expanded={Boolean(restOpen && model.auto && !model.autoRest)} onClick={() => {
                  if (model.autoRest) { onChange('autoRest', false); setRestOpen(false); }
                  else setRestOpen((value) => !value);
                }}>{model.autoRest ? c.resumeAuto : c.restAuto}</button>
                {restOpen && model.auto && !model.autoRest && (
                  <div className="s-rest-menu" role="menu" aria-label={c.restMenu}>
                    {c.restOptions.map(([value, label]) => <button key={value} type="button" role="menuitem" onClick={() => { onChange('autoRest', value); setRestOpen(false); }}>{label}</button>)}
                  </div>
                )}
              </div>
            </div>
          </Section>
          <Section title={c.unplugged} footer={model.sleepAction === 'system' ? c.systemSleepFooter : c.sleepFooter}>
            <div className="s-group">
              <SelectRow label={c.awake} value={model.disconnect} onChange={(value) => onChange('disconnect', value)} options={c.disconnectOptions} />
              <div className="s-policy-preview" aria-live="polite">
                <p>{c.disconnectDescriptions[model.disconnect]}</p>
                {model.disconnect !== 'all' && <p className="s-policy-note">{c.continuedPolicyNote}</p>}
              </div>
              <SelectRow label={c.lidClosed} value={model.sleepAction ?? 'sleep'} onChange={(value) => onChange('sleepAction', value)} options={c.sleepOptions} />
            </div>
          </Section>
          <p className="s-end-note">{c.batteryStart}</p>
        </>
      )}
      {tab === 'app' && (
        <>
          <Section title={c.general}>
            <div className="s-group">
              <ToggleRow label={c.login} checked={model.login} onChange={(value) => onChange('login', value)} />
              <SelectRow label={c.menuText} value={model.menuText} onChange={(value) => onChange('menuText', value)} options={c.menuOptions} />
              <SelectRow label={c.language} value={model.language} onChange={(value) => onChange('language', value)} options={c.languageOptions} />
              <SelectRow label={c.appearance} value={model.appearance ?? 'system'} onChange={(value) => onChange('appearance', value)} options={c.appearanceOptions} />
            </div>
          </Section>
          <Section title={c.notifications}>
            <div className="s-group">
              <ToggleRow label={c.endNotify} checked={model.endNotify} onChange={(value) => onChange('endNotify', value)} />
              <ToggleRow label={c.preNotify} checked={model.preNotify} onChange={(value) => onChange('preNotify', value)} />
            </div>
          </Section>
          <Section title={c.records}>
            <div className="s-group">
              <Disclosure title={c.usage} expandAll={expandAll}><EmptyExample>{c.noUsage}</EmptyExample></Disclosure>
              <Disclosure title={c.recent} expandAll={expandAll}><EmptyExample>{c.noRecent}</EmptyExample></Disclosure>
              <Disclosure title={c.appsHelpers} expandAll={expandAll}>
                <EmptyExample>{c.noAppInfo}</EmptyExample>
                <div className="s-info-row"><span>{c.otherApps}</span><span>—</span></div>
                <div className="s-info-row"><span>{c.helper}</span><span>—</span></div>
              </Disclosure>
              <Disclosure title={c.logsReports} expandAll={expandAll}>
                <SelectRow label={c.logWindow} value={model.logWindow ?? '60'} onChange={(value) => onChange('logWindow', value)} options={durationOptions([15, 60, 240])} />
                <div className="s-recording-row">
                  <span className="s-recording-state" aria-live="polite">{model.recording && <span className="s-recording-dot" aria-hidden="true" />}{model.recording ? c.recording : c.notRecording}</span>
                  <button type="button" className="s-button" onClick={() => onChange('recording', !model.recording)}>{model.recording ? c.stopRecording : c.startRecording}</button>
                </div>
                <SelectRow label={c.reportWindow} value={model.reportWindow ?? '60'} onChange={(value) => onChange('reportWindow', value)} options={c.reportOptions} />
                <div className="s-detail-actions">
                  <span className="s-detail-note">{c.noSavedRecords}</span>
                  <button type="button" className="s-button" disabled>{c.saveReport}</button>
                </div>
              </Disclosure>
            </div>
          </Section>
          <Section title={c.updates}><UpdateCard model={model} onChange={onChange} copy={c} locale={resolvedLocale} /></Section>
        </>
      )}
    </div>
  );
}
