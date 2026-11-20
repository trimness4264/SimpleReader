((initialStyle) => {
  let style;
  let pending = false;
  let pointerStart;
  let dragged = false;
  let tapTimer;
  const post = body => window.webkit.messageHandlers.continuousChapterHeight.postMessage(body);

  document.addEventListener('pointerdown', event => {
    clearTimeout(tapTimer);
    pointerStart = {x: event.clientX, y: event.clientY};
    dragged = false;
  }, {passive: true});
  document.addEventListener('pointermove', event => {
    if (pointerStart && Math.hypot(event.clientX - pointerStart.x, event.clientY - pointerStart.y) > 8) dragged = true;
  }, {passive: true});
  document.addEventListener('pointercancel', () => { dragged = true; pointerStart = undefined; }, {passive: true});
  document.addEventListener('click', event => {
    clearTimeout(tapTimer);
    if (dragged || event.defaultPrevented || event.detail > 1 || window.getSelection()?.isCollapsed === false
        || event.target.closest('a,button,input,textarea,select,label,[contenteditable="true"],[role="button"]')
        || event.clientX < innerWidth * 0.2 || event.clientX > innerWidth * 0.8) return;
    tapTimer = setTimeout(() => {
      if (!dragged && window.getSelection()?.isCollapsed !== false) post({tap: true});
    }, 250);
  });

  function measure() {
    if (!document.body || pending) return;
    pending = true;
    requestAnimationFrame(() => {
      pending = false;
      const body = document.body;
      post({height: Math.ceil(Math.max(body.scrollHeight, body.getBoundingClientRect().height))});
    });
  }

  window.SimpleReaderContinuousStyle = css => {
    if (!document.body) return;
    if (!style) {
      style = document.createElement('style');
      style.dataset.simpleReaderInert = '';
      document.head.append(style);
    }
    style.textContent = css;
    measure();
  };

  window.SimpleReaderContinuousOffset = location => {
    let element;
    if (location.selector) { try { element = document.querySelector(location.selector); } catch (_) {} }
    if (!element && location.fragment) {
      let id = location.fragment;
      try { id = decodeURIComponent(id); } catch (_) {}
      element = document.getElementById(id);
    }
    if (element) {
      const node = element.childNodes[location.textNodeIndex];
      if (node?.nodeType === Node.TEXT_NODE && Number.isInteger(location.textOffset) && location.textOffset >= 0) {
        const range = SimpleReaderBridge.textRange(node, Math.min(node.length, location.textOffset));
        return window.scrollY + range.getBoundingClientRect().top;
      }
      if (location.highlight) {
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        let node;
        while (node = walker.nextNode()) {
          const index = node.data.indexOf(location.highlight);
          if (index >= 0) {
            const range = document.createRange();
            range.setStart(node, index);
            range.setEnd(node, Math.min(node.length, index + 1));
            return window.scrollY + range.getBoundingClientRect().top;
          }
        }
      }
      return window.scrollY + element.getBoundingClientRect().top;
    }
    return Math.max(0, document.body.scrollHeight * location.progression);
  };

  function start() {
    const viewport = document.createElement('meta');
    viewport.name = 'viewport';
    viewport.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no';
    document.head.append(viewport);
    window.SimpleReaderContinuousStyle(initialStyle);
    new ResizeObserver(measure).observe(document.body);
    window.addEventListener('load', measure);
    document.fonts?.ready.then(measure);
  }
  document.addEventListener('DOMContentLoaded', start, {once: true});
  if (document.readyState !== 'loading') start();
})
