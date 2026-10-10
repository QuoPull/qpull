/* QuoPull daily checklist: a floating, collapsible card shown on every page.
 *
 * WHY: players reported the site gives no clear direction. The four actions below are the whole
 * routine, and three of them are time-bound, so a persistent reminder beats a docs page nobody opens.
 *
 * It injects its own markup and styles, uses the site's existing CSS variables so it themes itself
 * light/dark with no extra work, and remembers whether it was open, collapsed or dismissed.
 * CSP-safe: same-origin script, inline <style> allowed by style-src 'unsafe-inline'.
 */
(function () {
  "use strict";
  var KEY = "quopull-checklist";           // "open" | "min" | "off"
  // localStorage throws in some privacy modes, so every access is guarded and the widget still works.
  function get() { try { return localStorage.getItem(KEY); } catch (_) { return null; } }
  function set(v) { try { localStorage.setItem(KEY, v); } catch (_) {} }

  var STEPS = [
    { when: "Before 9:00", note: "every day",      title: "Pledge your Art Pass",
      body: "Common, Uncommon and Rare must be pledged <b>every day</b>. Yesterday's pledge does not carry over. A Super Rare enters on its own and cannot be pledged." },
    { when: "After 10:00", note: "the draw runs",  title: "Check the draw log",
      body: "Winners are picked an hour after entries close, from randomness that did not exist while the window was open." },
    { when: "If you won",  note: "30 days",        title: "Claim it yourself",
      body: "Only the winner can claim. No keeper, no admin and nobody at QuoPull can do it for you. Unclaimed prizes return to the pot after 30 days." },
    { when: "Any time",    note: "optional",       title: "Rip packs you hold",
      body: "An unripped pack is in no draw. Ripping reveals its tier, enters that ticket in the next 7 draws, and banks XP toward the weekly leaderboard." }
  ];

  var css = ''
    + '#qp-dc{position:fixed;right:16px;bottom:16px;z-index:9990;font-family:var(--sans,system-ui);max-width:min(380px,calc(100vw - 32px))}'
    + '#qp-dc *{box-sizing:border-box}'
    + '#qp-dc .qp-tab{display:flex;align-items:center;gap:9px;background:var(--accent,#D6321F);color:#fff;border:0;'
    +   'font-family:var(--mono,monospace);font-size:11px;letter-spacing:.12em;text-transform:uppercase;'
    +   'padding:11px 15px;cursor:pointer;box-shadow:0 8px 24px -10px rgba(0,0,0,.55)}'
    + '#qp-dc .qp-tab:hover{filter:brightness(1.08)}'
    + '#qp-dc .qp-panel{background:var(--card,#F3F1EB);border:1px solid var(--ink,#14161A);'
    +   'box-shadow:0 18px 44px -18px rgba(0,0,0,.5);max-height:min(74vh,620px);display:flex;flex-direction:column}'
    + '#qp-dc .qp-hd{display:flex;align-items:center;gap:10px;padding:13px 14px;border-bottom:1px solid var(--stock-edge,#C9C5B8);flex:0 0 auto}'
    + '#qp-dc .qp-hd b{font-size:15px;color:var(--ink,#14161A);letter-spacing:-.01em}'
    + '#qp-dc .qp-hd .qp-sp{margin-left:auto;display:flex;gap:4px}'
    + '#qp-dc .qp-ico{background:none;border:1px solid var(--stock-edge,#C9C5B8);color:var(--ink-soft,#5C5C57);'
    +   'width:28px;height:28px;font-size:14px;line-height:1;cursor:pointer;border-radius:0}'
    + '#qp-dc .qp-ico:hover{border-color:var(--accent,#D6321F);color:var(--accent,#D6321F)}'
    + '#qp-dc .qp-body{overflow-y:auto;padding:2px 0}'
    + '#qp-dc .qp-s{padding:13px 14px;border-bottom:1px solid var(--stock-edge,#C9C5B8)}'
    + '#qp-dc .qp-s:last-child{border-bottom:none}'
    + '#qp-dc .qp-w{font-family:var(--mono,monospace);font-size:11px;color:var(--accent,#D6321F);letter-spacing:.04em}'
    + '#qp-dc .qp-w span{color:var(--ink-faint,#918D80);letter-spacing:.1em;text-transform:uppercase;margin-left:7px}'
    + '#qp-dc .qp-t{font-size:16px;font-weight:800;color:var(--ink,#14161A);margin-top:5px;letter-spacing:-.01em}'
    + '#qp-dc .qp-d{font-size:12.5px;line-height:1.55;color:var(--ink-soft,#5C5C57);margin-top:5px}'
    + '#qp-dc .qp-d b{color:var(--ink,#14161A)}'
    + '#qp-dc .qp-ft{padding:10px 14px;border-top:1px solid var(--stock-edge,#C9C5B8);flex:0 0 auto;'
    +   'font-family:var(--mono,monospace);font-size:10.5px;color:var(--ink-faint,#918D80);letter-spacing:.03em}'
    + '@media (max-width:520px){'
    +   '#qp-dc{right:10px;bottom:10px;left:auto;max-width:calc(100vw - 20px)}'
    +   '#qp-dc.qp-expanded{left:10px;max-width:none}'
    + '}'
    + '@media (prefers-reduced-motion:no-preference){#qp-dc .qp-panel,#qp-dc .qp-tab{animation:qpfade .18s ease-out}'
    +   '@keyframes qpfade{from{opacity:0;transform:translateY(6px)}to{opacity:1;transform:none}}}';

  function esc(s) { return String(s).replace(/&/g, "&amp;").replace(/</g, "&lt;"); }

  function render(state) {
    var el = document.getElementById("qp-dc");
    if (!el) return;
    // The container must be content-width while minimised. At <=520px it used to keep left:10px,
    // so the tab rendered at the LEFT edge, straight on top of .g-toast (left:20px, z-index 9998).
    // That hid error messages behind the checklist. Only the open panel spans the width now.
    el.classList.toggle("qp-expanded", state === "open");
    if (state === "off") { el.innerHTML = ""; return; }
    if (state === "min") {
      el.innerHTML = '<button class="qp-tab" id="qp-open" type="button">'
        + '<span aria-hidden="true">&#9776;</span> Daily checklist</button>';
      document.getElementById("qp-open").addEventListener("click", function () { set("open"); render("open"); });
      return;
    }
    var rows = STEPS.map(function (s) {
      return '<div class="qp-s"><div class="qp-w">' + esc(s.when) + '<span>' + esc(s.note) + '</span></div>'
        + '<div class="qp-t">' + esc(s.title) + '</div>'
        + '<div class="qp-d">' + s.body + '</div></div>';
    }).join("");
    el.innerHTML = '<div class="qp-panel">'
      + '<div class="qp-hd"><b>Your day on QuoPull</b><div class="qp-sp">'
      +   '<button class="qp-ico" id="qp-min" type="button" title="Minimise" aria-label="Minimise">&minus;</button>'
      +   '<button class="qp-ico" id="qp-off" type="button" title="Hide" aria-label="Hide">&times;</button>'
      + '</div></div>'
      + '<div class="qp-body">' + rows + '</div>'
      + '<div class="qp-ft">All times MST. Nothing happens on your behalf except a Super Rare entering.</div>'
      + '</div>';
    document.getElementById("qp-min").addEventListener("click", function () { set("min"); render("min"); });
    document.getElementById("qp-off").addEventListener("click", function () { set("off"); render("off"); });
  }

  function boot() {
    if (document.getElementById("qp-dc")) return;
    var st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);
    var host = document.createElement("div"); host.id = "qp-dc"; document.body.appendChild(host);
    // Default to MINIMISED, not open: a panel that covers content on first load is the complaint,
    // not the fix. It opens on one click and remembers the choice from then on.
    render(get() || "min");
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", boot);
  else boot();
})();
