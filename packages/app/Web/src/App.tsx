import React, { useEffect } from 'react';
import { Sidebar } from './components/Sidebar';
import { ChatView } from './components/ChatView';
import { SettingsPanel } from './components/SettingsPanel';
import { useAppStore } from './stores/appStore';
import './styles/global.css';

function App() {
  const { theme, showSettings, setShowSettings, loadModels, loadTools, loadModes } = useAppStore();

  useEffect(() => {
    loadModels();
    loadTools();
    loadModes();
  }, []);

  useEffect(() => {
    document.documentElement.setAttribute('data-theme', theme);
  }, [theme]);

  return (
    <div className="app-container">
      <Sidebar onSettingsClick={() => setShowSettings(!showSettings)} />
      <main className="main-content">
        <ChatView />
      </main>
      {showSettings && <SettingsPanel onClose={() => setShowSettings(false)} />}
    </div>
  );
}

export default App;
