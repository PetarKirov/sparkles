// ci perf site: the charts' legend toggles and tooltips (observability §17).
// The pages read without it; it requests nothing (OBW3).
//
// Markup it reads: a `.slot` (a column, a bar row, a timeline row, a point)
// names its X in `data-x`; a `.seg` inside names its series in `data-k` and
// its value in `data-n`; the nearest `data-u` gives the unit: `min`, `s`
// (seconds, shown as a duration), `jobs` or none.
(() => {
  'use strict';

  const tip = document.createElement('div');
  tip.className = 'tip';
  tip.setAttribute('role', 'tooltip');
  tip.hidden = true;
  document.body.append(tip);

  const number = n =>
    Math.abs(n) >= 10 || Number.isInteger(n)
      ? Math.round(n).toLocaleString('en-US')
      : n.toFixed(1);

  const format = (n, unit) => {
    if (unit === 's') {
      const m = n / 60;
      return m >= 120 ? (m / 60).toFixed(1) + ' h' : number(m) + ' min';
    }
    return unit ? number(n) + ' ' + unit : number(n);
  };

  const unitOf = el => {
    const u = el.closest('[data-u]');
    return u ? u.dataset.u : '';
  };

  const swatchOf = seg => {
    const style = getComputedStyle(seg);
    return style.backgroundImage !== 'none'
      ? style.backgroundImage
      : style.backgroundColor;
  };

  const row = (label, value, swatch, strong) => {
    const r = document.createElement('div');
    r.className = strong ? 'row hot' : 'row';
    const i = document.createElement('i');
    if (swatch) i.style.background = swatch;
    const k = document.createElement('span');
    k.textContent = label;
    const v = document.createElement('span');
    v.className = 'v';
    v.textContent = value;
    r.append(i, k, v);
    return r;
  };

  let hot = null;
  let slot = null;

  const show = target => {
    const s = target.closest('.slot');
    const seg = target.closest('.seg');
    if (hot && hot !== seg) hot.classList.remove('hot');
    if (seg && !seg.classList.contains('val')) seg.classList.add('hot');
    hot = seg;
    if (!s) {
      slot = null;
      tip.hidden = true;
      return;
    }
    slot = s;
    const segs = [...s.querySelectorAll('.seg')].filter(
      x => !x.classList.contains('off'),
    );
    tip.replaceChildren();
    const title = document.createElement('div');
    title.className = 'x';
    title.textContent = s.dataset.x || '';
    tip.append(title);
    // Top of a stack first, as drawn; a bar row's segments left to right.
    const ordered = s.matches('.col') ? segs.slice().reverse() : segs;
    let sum = 0;
    let counted = 0;
    const unit = unitOf(s);
    for (const x of ordered) {
      const u = x.dataset.u !== undefined ? x.dataset.u : unit;
      const n = Number(x.dataset.n);
      tip.append(
        row(
          x.dataset.k,
          format(n, u),
          x.classList.contains('val') ? '' : swatchOf(x),
          x === seg,
        ),
      );
      if (!x.classList.contains('val')) {
        sum += n;
        counted++;
      }
    }
    if (counted > 1) {
      const total = row('sum', format(sum, unit), '', false);
      total.classList.add('sum');
      tip.append(total);
    }
    tip.hidden = false;
  };

  const place = e => {
    if (tip.hidden) return;
    const pad = 14;
    const w = tip.offsetWidth;
    const h = tip.offsetHeight;
    let x = e.clientX + pad;
    let y = e.clientY + pad;
    if (x + w > innerWidth - 4) x = e.clientX - w - pad;
    if (y + h > innerHeight - 4) y = e.clientY - h - pad;
    tip.style.left = Math.max(4, x) + 'px';
    tip.style.top = Math.max(4, y) + 'px';
  };

  document.addEventListener('pointerover', e => {
    show(e.target);
    place(e);
  });
  document.addEventListener('pointermove', place);
  document.addEventListener('pointerleave', () => {
    tip.hidden = true;
  });

  // A legend entry hides its series in its panel, and shows it again.
  document.addEventListener('click', e => {
    const key = e.target.closest('.key');
    if (!key) return;
    const on = key.getAttribute('aria-pressed') !== 'false';
    key.setAttribute('aria-pressed', on ? 'false' : 'true');
    const panel = key.closest('.panel');
    for (const el of panel.querySelectorAll('[data-k]')) {
      if (!el.classList.contains('key') && el.dataset.k === key.dataset.k)
        el.classList.toggle('off', on);
    }
    // A clipped column's total no longer holds while a series is hidden.
    panel.classList.toggle(
      'filtered',
      panel.querySelector(".key[aria-pressed='false']") !== null,
    );
    if (slot) show(hot || slot);
  });
})();
