/* SPDX-License-Identifier: AGPL-3.0-or-later
 * DOM/XPointer routines adapted from Readest's XCFI (readest/readest,
 * apps/readest-app/src/utils/xcfi.ts). See THIRD_PARTY_NOTICES.md.
 * Changes: removed CFI dependency; added Readium viewport capture and Locator output.
 */
(function () {
  'use strict';
  const PRE = new Set(['pre','code','listing','plaintext','xmp','textarea']);
  const BLOCK = new Set(['body','div','p','h1','h2','h3','h4','h5','h6','ul','ol','li','dl','dt','dd','blockquote','pre','section','article','aside','header','footer','nav','main','figure','figcaption','table','thead','tbody','tfoot','tr','td','th','caption','address','details','summary','form','fieldset','center']);
  const inert = e => e.hasAttribute('cfi-inert') || e.matches('script,style,#readium-virtual-page,[data-simple-reader-inert]');
  const transparent = e => e.hasAttribute('cfi-skip');
  function children(e) {
    const out = [];
    for (const c of e.children) {
      if (inert(c)) continue;
      if (transparent(c)) out.push(...children(c)); else out.push(c);
    }
    return out;
  }
  function parent(e) { let p = e.parentElement; while (p && transparent(p)) p = p.parentElement; return p; }
  function pre(e) { for (; e; e = e.parentElement) if (PRE.has(e.tagName.toLowerCase())) return true; return false; }
  function textChildren(e) {
    return Array.from(e.childNodes).filter((n,i) => n.nodeType === Node.TEXT_NODE && n.data.length && !(i === 0 && BLOCK.has(e.tagName.toLowerCase()) && !pre(e) && !n.data.trim()));
  }
  const continuation = (s,i) => i > 0 && /[ \t\n\r\f]/.test(s[i]) && /[ \t\n\r\f]/.test(s[i-1]);
  function collapsedOffset(node, offset) {
    if (pre(node.parentElement)) return offset;
    let count = 0; for (let i = 0; i < Math.min(offset,node.length); i++) if (!continuation(node.data,i)) count++;
    return count;
  }
  function rawOffset(node, offset) {
    if (pre(node.parentElement)) { if (offset > node.length) throw Error('Text offset exceeds node'); return offset; }
    let count = 0;
    for (let i = 0; i < node.length; i++) { if (continuation(node.data,i)) continue; if (count === offset) return i; count++; }
    if (count === offset) return node.length;
    throw Error('Text offset exceeds node');
  }
  function path(e, spine, single) {
    const parts = [];
    while (e && e !== document.body) {
      if (inert(e)) throw Error('Position is in an injected node');
      if (transparent(e)) { e = e.parentElement; continue; }
      const p = parent(e); if (!p) throw Error('Position outside body');
      const siblings = children(p).filter(c => c.tagName === e.tagName);
      const i = siblings.indexOf(e); if (i < 0) throw Error('Unaddressable node');
      parts.unshift(e.tagName.toLowerCase() + (siblings.length > 1 ? '[' + (i+1) + ']' : ''));
      e = p;
    }
    if (e !== document.body) throw Error('Position outside body');
    return '/body/DocFragment' + (single ? '' : '[' + (spine+1) + ']') + '/body' + (parts.length ? '/' + parts.join('/') : '');
  }
  function fromPoint(node, offset, spine, single) {
    if (node.nodeType !== Node.TEXT_NODE) return path(node,spine,single);
    const e = node.parentElement;
    const siblings = textChildren(e), index = siblings.indexOf(node);
    const base = path(e,spine,single);
    if (index < 0) return base;
    return base + '/text()' + (siblings.length > 1 ? '[' + (index+1) + ']' : '') + '.' + collapsedOffset(node,offset);
  }
  function selector(e) {
    const parts = [];
    while (e && e !== document.body) {
      const index = Array.from(e.parentElement.children).indexOf(e)+1;
      parts.unshift(e.tagName.toLowerCase()+':nth-child('+index+')'); e = e.parentElement;
    }
    return 'body' + (parts.length ? ' > '+parts.join(' > ') : '');
  }
  function resolve(pointer) {
    const m = pointer.match(/^\/body\/DocFragment(?:\[(\d+)\])?\/body(.*)$/);
    if (!m) throw Error('Unsupported XPointer');
    const spine = m[1] ? Number(m[1])-1 : 0;
    let tail = m[2], node = null, raw = 0;
    const text = tail.match(/\/text\(\)(?:\[(\d+)\])?\.(\d+)$/);
    const elementOffset = !text && tail.match(/\.(\d+)$/);
    if (text) tail = tail.slice(0, text.index);
    else if (elementOffset) tail = tail.slice(0, elementOffset.index);
    let e = document.body;
    for (const segment of tail.split('/').filter(Boolean)) {
      const s = segment.match(/^(\w+)(?:\[(\d+)\])?$/); if (!s) throw Error('Invalid path segment');
      const list = children(e).filter(c => c.tagName.toLowerCase() === s[1].toLowerCase());
      e = list[s[2] ? Number(s[2])-1 : 0]; if (!e) throw Error('XPointer node not found');
    }
    if (text) {
      node = textChildren(e)[text[1] ? Number(text[1])-1 : 0];
      if (!node) throw Error('Text node not found'); raw = rawOffset(node,Number(text[2]));
    } else if (elementOffset) {
      const walker = document.createTreeWalker(e,NodeFilter.SHOW_TEXT); let remaining = Number(elementOffset[1]);
      while ((node = walker.nextNode())) { const length = collapsedOffset(node,node.length); if (remaining <= length) { raw = rawOffset(node,remaining); break; } remaining -= length; }
      if (!node) throw Error('Text offset not found');
    }
    const quote = node ? node.data.slice(raw,raw+64) : '';
    return {spine, textNodeIndex:node ? Array.from(node.parentElement.childNodes).indexOf(node) : null, textOffset:raw, cssSelector:selector(node ? node.parentElement : e), highlight:quote, before:node ? node.data.slice(Math.max(0,raw-32),raw) : '', after:node ? node.data.slice(raw+64,raw+96) : ''};
  }
  function capture(spine, single) {
    const walker = document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT,{
      acceptNode(n) {
        if (!n.data.trim()) return NodeFilter.FILTER_REJECT;
        for (let e = n.parentElement; e; e = e.parentElement) if (inert(e)) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    let node;
    while ((node = walker.nextNode())) {
      const r = document.createRange(); r.selectNodeContents(node);
      if (!Array.from(r.getClientRects()).some(v => v.width > 0 && v.height > 0 && v.right > 0 && v.left < innerWidth && v.bottom > 0 && v.top < innerHeight)) continue;
      // Binary search is unsafe for paginated ranges. Test each character of the visible text node.
      for (let offset = 0; offset < node.length; offset++) {
        r.setStart(node,offset); r.setEnd(node,offset+1);
        const v = r.getBoundingClientRect();
        if (v.width > 0 && v.height > 0 && v.right > 0 && v.left < innerWidth && v.bottom > 0 && v.top < innerHeight) return fromPoint(node,offset,spine,single);
      }
    }
    throw Error('No visible正文 position; upload deferred');
  }
  window.SimpleReaderBridge = {capture,resolve,fromPoint};
})();
