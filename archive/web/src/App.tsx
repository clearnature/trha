import React, { useEffect, useState } from 'react';
import { AppFrame } from './layout/AppFrame';
import { Sidebar } from './components/Sidebar';
import { ChatView } from './components/ChatView';
import { SettingsPanel } from './components/SettingsPanel';
import { RightPanel } from './components/RightPanel';
import { useAppStore } from './stores/appStore';
import { RIGHTBAR_DEFAULT_RATIO, SIDEBAR_AUTO_COLLAPSE, SIDEBAR_DEFAULT } from './layout/columns';
import './styles/tokens.css';
import './styles/global.css';

function initialSidebarWidth(): number {
  if (typeof window !== 'undefined' && window.innerWidth < SIDEBAR_AUTO_COLLAPSE) return 0;
  return SIDEBAR_DEFAULT;
}

function App() {
  const {
    theme, showSettings, setShowSettings,
    currentSession, loadModels, loadTools, loadModes,
    refreshSessionInfo, loadAgents, loadFiles, subscribeEvents, loadPermission,
    rightPanel,
  } = useAppStore();
  const [sidebarWidth, setSidebarWidth] = useState(initialSidebarWidth);
  const [rightbarWidth, setRightbarWidth] = useState(0);

  useEffect(() => {
    void loadModels();
    void loadTools();
    void loadModes();
    void loadFiles();
  }, [loadModels, loadTools, loadModes, loadFiles]);

  // Live sidebar facts: refreshed on session switch and while a turn is running.
  useEffect(() => {
    if (!currentSession) return;
    void refreshSessionInfo();
    void loadAgents();
    void loadFiles();
    void loadPermission();
    const timer = setInterval(() => {
      void refreshSessionInfo();
      void loadAgents();
    }, 4000);
    return () => clearInterval(timer);
  }, [currentSession?.id, refreshSessionInfo, loadAgents, loadFiles, loadPermission]);

  // Live turn events (tool progress / reasoning) for the active session.
  useEffect(() => {
    if (!currentSession) return;
    return subscribeEvents(currentSession.id);
  }, [currentSession?.id, subscribeEvents]);

  // The right column only gets a track while it has an occupant; its first
  // open width follows the reference ratio and is clamped by computeColumns.
  useEffect(() => {
    if (!rightPanel) {
      setRightbarWidth(0);
      return;
    }
    setRightbarWidth(Math.round(window.innerWidth * RIGHTBAR_DEFAULT_RATIO));
  }, [rightPanel?.path]);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  const collapsed = sidebarWidth === 0;

  return (
    <>
      <AppFrame
        sidebarWidth={sidebarWidth}
        onSidebarWidthChange={setSidebarWidth}
        sidebar={
          <Sidebar
            collapsed={collapsed}
            onToggle={() => setSidebarWidth(collapsed ? SIDEBAR_DEFAULT : 0)}
            onSettingsClick={() => setShowSettings(!showSettings)}
          />
        }
        main={<ChatView />}
        rightbar={rightPanel ? <RightPanel /> : undefined}
        rightbarWidth={rightbarWidth}
      />
      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}
    </>
  );
}

export default App;
