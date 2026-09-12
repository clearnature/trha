import React, { useEffect, useState } from 'react';
import { Shell } from './ui/Shell';
import { Sidebar } from './ui/Sidebar';
import { StatusBar } from './ui/StatusBar';
import { MessageList } from './ui/MessageList';
import { Composer } from './ui/Composer';
import { ModelPicker } from './ui/ModelPicker';
import { PlanPrompt } from './ui/PlanPrompt';
import { SessionProvider, useSessionStore } from './ui/SessionContext';
import { PrefsProvider, usePrefs } from './ui/PrefsContext';
import { SettingsPanel } from './ui/SettingsPanel';
import { initAPI } from './stores/appStore';

function Workspace({ onSettingsClick }: { onSettingsClick: () => void }) {
  const store = useSessionStore();

  useEffect(() => {
    initAPI().then(async () => {
      const s = store.getState();
      await s.loadCatalog();
      await s.refresh();
      await s.loadVersion();
    });
  }, [store]);

  return (
    <Shell sidebar={<Sidebar onSettingsClick={onSettingsClick} />} statusBar={<StatusBar />}>
      <div className="chat-view">
        <MessageList />
        <PlanPrompt />
        <ModelPicker />
        <Composer />
      </div>
    </Shell>
  );
}

/** Applies theme + font size from prefs to the document root. */
function useApplyPrefs() {
  const { prefs } = usePrefs();
  useEffect(() => {
    document.documentElement.setAttribute('data-theme', prefs.theme);
    document.documentElement.style.fontSize = `${prefs.fontSize}px`;
    document.documentElement.setAttribute('lang', prefs.lang);
  }, [prefs.theme, prefs.fontSize, prefs.lang]);
}

function Root() {
  const [showSettings, setShowSettings] = useState(false);
  useApplyPrefs();

  return (
    <div className="app-root">
      <Workspace onSettingsClick={() => setShowSettings(v => !v)} />
      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}
    </div>
  );
}

function App() {
  return (
    <PrefsProvider>
      <SessionProvider>
        <Root />
      </SessionProvider>
    </PrefsProvider>
  );
}

export default App;
