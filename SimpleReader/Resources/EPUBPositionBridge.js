/* SPDX-License-Identifier: AGPL-3.0-or-later
 * DOM/XPointer routines adapted from Readest's XCFI (readest/readest,
 * apps/readest-app/src/utils/xcfi.ts). See THIRD_PARTY_NOTICES.md.
 * Changes: removed CFI dependency; added Readium viewport capture and Locator output.
 */
(function () {
  'use strict';
  const PRE = new Set(['pre','listing','plaintext','xmp','textarea']);
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
  const isFoldedWhitespace = (text, index, preserveWhitespace) =>
    !preserveWhitespace && index > 0 && /[ \t\n\r\f]/.test(text[index]) && /[ \t\n\r\f]/.test(text[index - 1]);
  const codePointWidth = (text, index) => text.codePointAt(index) > 0xffff ? 2 : 1;

  // DOM Range offsets count UTF-16 units. CREngine counts code points after
  // folding whitespace, except in preformatted text where every space counts.
  function collapsedOffset(node, offset) {
    const text = node.data;
    const preserveWhitespace = pre(node.parentElement);
    const limit = Math.min(offset, text.length);
    let count = 0;
    for (let i = 0; i < limit;) {
      const next = i + codePointWidth(text, i);
      if (next > limit) break;
      if (!isFoldedWhitespace(text, i, preserveWhitespace)) count++;
      i = next;
    }
    return count;
  }
  function rawOffset(node, offset) {
    const text = node.data;
    const preserveWhitespace = pre(node.parentElement);
    let count = 0;
    for (let i = 0; i < text.length; i += codePointWidth(text, i)) {
      if (isFoldedWhitespace(text, i, preserveWhitespace)) continue;
      if (count === offset) return i;
      count++;
    }
    if (count === offset) return text.length;
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
      // CREngine can express an element start as img.0/body.0 without text.
      if (!node && Number(elementOffset[1]) !== 0) throw Error('Text offset not found');
    }
    const quote = node ? node.data.slice(raw,raw+64) : '';
    return {spine, textNodeIndex:node ? Array.from(node.parentElement.childNodes).indexOf(node) : null, textOffset:raw, cssSelector:selector(node ? node.parentElement : e), highlight:quote, before:node ? node.data.slice(Math.max(0,raw-32),raw) : '', after:node ? node.data.slice(raw+64,raw+96) : ''};
  }
  function intersectsViewport(rect, viewport = {top: 0, bottom: innerHeight}) {
    return rect.width > 0 && rect.height > 0 && rect.right > 0 && rect.left < innerWidth &&
      rect.bottom > viewport.top && rect.top < viewport.bottom;
  }

  function capture(spine, single) {
    if (!document.body || document.readyState === 'loading') throw Error('Chapter is still loading');
    const viewport = window.SimpleReaderViewport;
    const visible = rect => intersectsViewport(rect, viewport);
    // Keep text and media in document order, so a picture before a caption
    // anchors to the picture. Ignore layout containers and injected content.
    const walker = document.createTreeWalker(document.body,NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT,{
      acceptNode(n) {
        for (let e = n.nodeType === Node.ELEMENT_NODE ? n : n.parentElement; e; e = e.parentElement) if (inert(e)) return NodeFilter.FILTER_REJECT;
        if (n.nodeType === Node.ELEMENT_NODE) {
          if (!n.matches('img,svg,object,video,canvas')) return NodeFilter.FILTER_SKIP;
          return Array.from(n.getClientRects()).some(visible) ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT;
        }
        if (!n.data.trim()) return NodeFilter.FILTER_REJECT;
        return NodeFilter.FILTER_ACCEPT;
      }
    });
    let node;
    while ((node = walker.nextNode())) {
      if (node.nodeType === Node.ELEMENT_NODE) return fromPoint(node,0,spine,single);
      const r = document.createRange(); r.selectNodeContents(node);
      if (!Array.from(r.getClientRects()).some(visible)) continue;
      // Binary search is unsafe for paginated ranges. Test each character of the visible text node.
      const text = node.data;
      for (let offset = 0; offset < text.length;) {
        const end = offset + codePointWidth(text, offset);
        r.setStart(node, offset); r.setEnd(node, end);
        const v = r.getBoundingClientRect();
        if (visible(v)) return fromPoint(node,offset,spine,single);
        offset = end;
      }
    }
    // Empty pages and CSS background covers still have a valid chapter anchor.
    return path(document.body,spine,single);
  }

  function presentation(href, target, spineIndices, single) {
    const root = document.scrollingElement;
    const width = window.innerWidth, height = window.innerHeight;
    const resource = window.readium?.link?.href;
    if (!resource || (href !== null && resource !== href) || !document.body || document.readyState !== 'complete' ||
        document.fonts?.status === 'loading' || !root?.scrollWidth || !width || !height) return null;

    const anchorVisible = rect => intersectsViewport(rect) ||
      ((!rect.width || !rect.height) && rect.left >= 0 && rect.left < width && rect.top >= 0 && rect.top < height);
    const offset = Math.abs(window.scrollX);
    const fixed = !!window.readium.isFixedLayout;
    if (target?.pointer) {
      let anchor;
      try { anchor = resolve(target.pointer); } catch (_) { return { href: resource, missingAnchor: true }; }
      const element = document.querySelector(anchor.cssSelector);
      const node = element?.childNodes[anchor.textNodeIndex];
      if (!element) return { href: resource, missingAnchor: true };
      let rects = element.getClientRects();
      if (node?.nodeType === Node.TEXT_NODE && node.length) {
        const offset = Math.min(anchor.textOffset, node.length - 1);
        const range = document.createRange();
        range.setStart(node, offset);
        range.setEnd(node, offset + 1);
        rects = range.getClientRects();
      }
      if (!Array.from(rects).some(anchorVisible)) {
        const rect = rects[0];
        // Locate the exact XPointer even when its text also occurs on another page.
        if (!fixed && rect) {
          const page = Math.floor((rect.left + window.scrollX + 1) / width) * width;
          return {href: resource, anchorProgression: Math.min(1, Math.abs(page) / root.scrollWidth)};
        }
        return null;
      }
    } else if (target?.fragment) {
      const element = document.getElementById(target.fragment);
      if (!element) return { href: resource, missingAnchor: true };
      if (!Array.from(element.getClientRects()).some(anchorVisible)) return null;
    } else if (!fixed && target) {
      // Readium rounds down to the start of a screen and clamps at the end.
      const targetOffset = Math.min(root.scrollWidth - width,
        Math.floor((root.scrollWidth * target.progression + 1) / width) * width);
      if (Math.abs(offset - Math.max(0, targetOffset)) > 2) return null;
    }

    const css = getComputedStyle(document.documentElement);
    window.SimpleReaderPresentationDocument ??= Math.random();
    let pointer = null;
    if (Object.hasOwn(spineIndices, resource)) {
      try { pointer = capture(spineIndices[resource], single); } catch (_) { /* The visible locator is still usable. */ }
    }
    return {
      href: resource,
      progression: fixed ? 0 : offset / root.scrollWidth,
      tolerance: 2 / root.scrollWidth,
      layout: [window.SimpleReaderPresentationDocument, width, height, root.scrollWidth, root.scrollHeight, offset, window.scrollY,
        css.columnCount, css.columnWidth, css.fontSize].join(':'),
      pointer
    };
  }

  window.SimpleReaderBridge = {capture,resolve,fromPoint,presentation};
})();
