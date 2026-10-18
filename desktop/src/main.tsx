import { render } from 'preact';
import './styles.css';
import { App } from './ui/app';

render(<App />, document.getElementById('app')!);

// Installed from Edge, the app opens in its own window and works offline (except speech, which uses the network).
if ('serviceWorker' in navigator && import.meta.env.PROD) {
  addEventListener('load', () => {
    void navigator.serviceWorker.register('./sw.js');
  });
}
