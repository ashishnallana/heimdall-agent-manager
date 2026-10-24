import { useEffect, useRef, useState } from 'react';
import { useDispatch, useSelector } from 'react-redux';
import { authenticatedStreamUrl } from './userStreamUrl';
import { ToolActivityStream, type ToolSubscription } from './toolActivityStream';

const streams = new WeakMap<object, ToolActivityStream>();
export function useToolActivityStream(ids: string[], conversationId = '', enabled = true) {
  const [visible, setVisible] = useState(() => !document.hidden);
  useEffect(() => {
    const changed = () => setVisible(!document.hidden);
    document.addEventListener('visibilitychange', changed);
    return () => document.removeEventListener('visibilitychange', changed);
  }, []);
  const watching = enabled && visible && Boolean(conversationId);
  const dispatch = useDispatch();
  const authKey = useSelector((state: any) => JSON.stringify([
    state.chat?.session?.userId || '', state.chat?.session?.daemonUrl || '',
    state.chat?.session?.clientToken || '',
  ]));
  let stream = streams.get(dispatch);
  if (!stream) {
    stream = new ToolActivityStream(dispatch, {
      now: () => performance.now(),
      url: (signal) => authenticatedStreamUrl('/api/v1/tool-activity/stream', signal),
      socket: (url) => new WebSocket(url),
      every: (callback, ms) => {
        const timer = window.setInterval(callback, ms);
        return () => window.clearInterval(timer);
      },
      onResume: (callback) => {
        const visible = () => { if (!document.hidden) callback(); };
        document.addEventListener('visibilitychange', visible);
        document.addEventListener('resume', callback);
        window.addEventListener('pageshow', callback);
        return () => {
          document.removeEventListener('visibilitychange', visible);
          document.removeEventListener('resume', callback);
          window.removeEventListener('pageshow', callback);
        };
      },
    });
    streams.set(dispatch, stream);
  }
  const handle = useRef<ToolSubscription | undefined>(undefined);
  const idsKey = JSON.stringify(watching ? [...new Set(ids)].sort() : []);
  useEffect(() => {
    handle.current = stream.subscribe(authKey, JSON.parse(idsKey), conversationId);
    return () => { handle.current?.release(); handle.current = undefined; };
  }, [stream, authKey, conversationId, watching]);
  useEffect(() => { handle.current?.update(JSON.parse(idsKey)); }, [idsKey]);
}
