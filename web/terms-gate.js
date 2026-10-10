/* QuoPull terms acknowledgment gate.
   Every visitor must tick a box acknowledging the Terms of use and the risks before using any page that
   loads this script (delegate.html, index.html, docs.html). terms.html does NOT load it, so the terms stay
   readable before anyone accepts. The choice is remembered per browser under TERMS_KEY; bump the version
   in TERMS_KEY when the terms change materially and everyone is asked again. It also sets the older
   quopull-tos flag that index.html's connect step checks, so nobody is asked twice. */
(function () {
  "use strict";
  var TERMS_KEY = "quopull-terms-v1";
  var TERMS_URL = "/terms.html";

  function accepted() {
    try { return localStorage.getItem(TERMS_KEY) === "1"; } catch (e) { return false; }
  }
  function remember() {
    try { localStorage.setItem(TERMS_KEY, "1"); localStorage.setItem("quopull-tos", "1"); } catch (e) {}
  }
  if (accepted()) return;

  var css =
    "#qp-gate{position:fixed;inset:0;z-index:2147483000;display:flex;align-items:center;justify-content:center;" +
    "padding:16px;background:rgba(20,22,26,.72);overflow:auto}" +
    "#qp-gate .qp-card{box-sizing:border-box;width:100%;max-width:520px;max-height:calc(100dvh - 32px);overflow:auto;" +
    "background:var(--card,#F3F1EB);color:var(--ink,#14161A);border:1px solid var(--stock-edge,#C9C5B8);" +
    "padding:24px 24px 20px;font-family:var(--sans,system-ui,-apple-system,Segoe UI,sans-serif);line-height:1.5}" +
    "#qp-gate .qp-eyebrow{font-family:var(--mono,ui-monospace,Menlo,monospace);font-size:10px;letter-spacing:.16em;" +
    "text-transform:uppercase;color:var(--accent,#D6321F);margin:0 0 6px}" +
    "#qp-gate h2{font-size:22px;line-height:1.15;margin:0 0 12px;font-weight:800}" +
    "#qp-gate ul{margin:0 0 16px;padding-left:18px;font-size:14.5px}" +
    "#qp-gate li{margin:0 0 6px}" +
    "#qp-gate label{display:flex;gap:10px;align-items:flex-start;font-size:14.5px;cursor:pointer;margin:0 0 16px}" +
    "#qp-gate input[type=checkbox]{width:18px;height:18px;margin:2px 0 0;flex:0 0 auto;accent-color:var(--accent,#D6321F)}" +
    "#qp-gate a{color:inherit;text-decoration:underline}" +
    "#qp-gate button{width:100%;padding:12px 16px;border:0;background:var(--ink,#14161A);color:var(--card,#F3F1EB);" +
    "font-family:var(--mono,ui-monospace,Menlo,monospace);font-size:12px;letter-spacing:.12em;text-transform:uppercase;cursor:pointer}" +
    "#qp-gate button:disabled{opacity:.45;cursor:not-allowed}" +
    "#qp-gate button:focus-visible,#qp-gate input:focus-visible,#qp-gate a:focus-visible{outline:2px solid var(--accent,#D6321F);outline-offset:2px}";

  function build() {
    if (document.getElementById("qp-gate")) return;
    var style = document.createElement("style");
    style.textContent = css;
    document.head.appendChild(style);

    var gate = document.createElement("div");
    gate.id = "qp-gate";
    gate.setAttribute("role", "dialog");
    gate.setAttribute("aria-modal", "true");
    gate.setAttribute("aria-labelledby", "qp-gate-h");
    gate.innerHTML =
      '<div class="qp-card">' +
      '<p class="qp-eyebrow">Before you continue</p>' +
      '<h2 id="qp-gate-h">QuoPull is a speculative experiment</h2>' +
      "<ul>" +
      "<li>It is experimental software on a public blockchain. You can lose everything you put in.</li>" +
      "<li>Nothing here is investment advice or a promise of profit. Prizes are decided by chance.</li>" +
      "<li>You hold your own keys. Transactions are final and cannot be reversed.</li>" +
      "<li>You must be an adult, and using QuoPull must be legal where you are.</li>" +
      "</ul>" +
      '<label><input type="checkbox" id="qp-gate-agree"> <span>I have read and agree to the ' +
      '<a href="' + TERMS_URL + '" target="_blank" rel="noopener">Terms of use</a>, and I understand the risks.</span></label>' +
      '<button type="button" id="qp-gate-go" disabled>Continue</button>' +
      "</div>";

    hideBehind(gate);
    var prevOverflow = document.documentElement.style.overflow;
    document.documentElement.style.overflow = "hidden";
    document.body.appendChild(gate);

    var box = document.getElementById("qp-gate-agree");
    var go = document.getElementById("qp-gate-go");
    box.addEventListener("change", function () { go.disabled = !box.checked; });
    go.addEventListener("click", function () {
      if (!box.checked) return;
      remember();
      Array.prototype.forEach.call(document.querySelectorAll("[data-qp-inert]"), function (el) {
        el.removeAttribute("inert"); el.removeAttribute("aria-hidden"); el.removeAttribute("data-qp-inert");
      });
      document.documentElement.style.overflow = prevOverflow;
      gate.remove();
      style.remove();
    });
    gate.addEventListener("keydown", function (e) {
      if (e.key !== "Tab") return;
      var f = [box, gate.querySelector("a"), go].filter(function (x) { return x && !x.disabled; });
      var i = f.indexOf(document.activeElement);
      if (e.shiftKey && (i <= 0)) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
    });
    box.focus();
  }

  // Everything else on the page is made inert (not clickable or focusable) until the box is ticked.
  function hideBehind(gate) {
    Array.prototype.forEach.call(document.body.children, function (el) {
      if (el === gate || el.tagName === "SCRIPT" || el.hasAttribute("data-qp-inert")) return;
      el.setAttribute("inert", ""); el.setAttribute("aria-hidden", "true"); el.setAttribute("data-qp-inert", "");
    });
  }

  if (document.body) build();
  else document.addEventListener("DOMContentLoaded", build);
  // The page's own content is parsed after this script runs, so hide those late arrivals too.
  document.addEventListener("DOMContentLoaded", function () {
    var gate = document.getElementById("qp-gate");
    if (gate) hideBehind(gate);
  });
})();
