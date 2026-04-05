// Content script — batch translation via JSON array format
if (window._voxLoaded) { /* already loaded */ } else {
window._voxLoaded = true;

let isTranslated = false;
let currentLanguage = "Auto";
let translatedNodes = new WeakSet();
let mutationObserver = null;
let pendingMutationTimer = null;
let isApplyingTranslation = false;

// chunk id -> array of text nodes
const nodeMap = new Map();
let nodeIdCounter = 0;

console.log("[Vox content] Content script loaded on:", window.location.href);
checkAutoTranslate();

// SPA navigation
let lastUrl = window.location.href;
const origPush = history.pushState;
history.pushState = function(...a) { origPush.apply(this, a); onUrlChange(); };
const origReplace = history.replaceState;
history.replaceState = function(...a) { origReplace.apply(this, a); onUrlChange(); };
window.addEventListener("popstate", () => onUrlChange());

function onUrlChange() {
    if (window.location.href === lastUrl) return;
    lastUrl = window.location.href;
    isTranslated = false;
    stopObserver();
    nodeMap.clear();
    translatedNodes = new WeakSet();
    nodeIdCounter = 0;
    setTimeout(() => checkAutoTranslate(), 800);
}

browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.action === "translatePage") translatePage(msg.targetLanguage);
    else if (msg.action === "restorePage") restorePage();
    else if (msg.action === "translationResult") applyTranslation(msg);
    else if (msg.action === "getStatus") sendResponse({ isTranslated });
});

// ---- Skip logic ----

const ICON_RE = /material-icons|fa\b|fa-|fas\b|far\b|fab\b|fal\b|glyphicon|bi\b|bi-/i;
const SKIP_TAGS = new Set(["script","style","noscript","svg","code","pre","textarea","input","select","canvas","iframe","video","audio"]);
const SKIP_ROLES = new Set(["slider","toolbar","menubar","menu","menuitem","menuitemcheckbox","dialog","alertdialog"]);

function shouldSkip(node) {
    const text = node.textContent.trim();
    if (text.length < 2) return true;
    if (/^[\d\s.,;:!?%$€£¥+\-*/=()[\]{}@#&|<>]+$/.test(text)) return true;

    const parent = node.parentElement;
    if (!parent) return true;

    // Skip already translated (marked on parent element)
    if (parent.hasAttribute("data-vox-done")) return true;

    // Icon detection
    const ptag = parent.tagName.toLowerCase();
    if ((ptag === "i" || ptag === "mat-icon") && (ICON_RE.test(parent.className) || (text.length < 30 && /^[a-z_]+$/.test(text)))) return true;
    if (ICON_RE.test(parent.className)) return true;
    if (parent.getAttribute("aria-hidden") === "true") return true;

    // Walk up ancestors
    let el = parent;
    while (el && el !== document.body) {
        const tag = el.tagName.toLowerCase();
        if (SKIP_TAGS.has(tag)) return true;
        const cls = el.className?.toString?.() || "";
        if (/vjs|video-js|plyr|mejs|jw-/i.test(cls)) return true;
        const aria = el.getAttribute("aria-label") || "";
        if (/video player|modal|caption/i.test(aria)) return true;
        const role = el.getAttribute("role") || "";
        if (SKIP_ROLES.has(role)) return true;
        if (tag === "dialog") return true;
        el = el.parentElement;
    }
    return false;
}

function collectTextNodes() {
    const nodes = [];
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    let n;
    while (n = walker.nextNode()) {
        if (!translatedNodes.has(n) && !shouldSkip(n)) nodes.push(n);
    }
    // Visible nodes first (top-to-bottom), then hidden (dropdowns, carousel slides)
    nodes.sort((a, b) => {
        const ar = a.parentElement?.getBoundingClientRect();
        const br = b.parentElement?.getBoundingClientRect();
        const aVis = ar && (ar.width > 0 || ar.height > 0);
        const bVis = br && (br.width > 0 || br.height > 0);
        if (aVis && !bVis) return -1;
        if (!aVis && bVis) return 1;
        return (ar?.top ?? 0) - (br?.top ?? 0);
    });
    return nodes;
}

// ---- Translate ----

const BATCH_SIZE = 30; // nodes per API request

function translatePage(targetLanguage) {
    currentLanguage = targetLanguage || "Auto";
    nodeMap.clear();
    nodeIdCounter = 0;
    setDomainAutoTranslate(currentLanguage);

    const textNodes = collectTextNodes();
    console.log("[Vox content] Found text nodes:", textNodes.length);
    if (!textNodes.length) return;
    isTranslated = true;

    const chunks = buildChunks(textNodes);
    console.log("[Vox content] Sending", chunks.length, "batches");
    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: currentLanguage
    });
}

function buildChunks(textNodes) {
    const chunks = [];
    for (let i = 0; i < textNodes.length; i += BATCH_SIZE) {
        const batch = textNodes.slice(i, i + BATCH_SIZE);
        const id = `vox-${nodeIdCounter++}`;
        const texts = [];
        for (const node of batch) {
            node._voxOriginal = node.textContent;
            if (node.parentElement) node.parentElement.style.opacity = "0.5";
            texts.push(node.textContent.trim());
        }
        nodeMap.set(id, batch);
        // Send as JSON array string
        chunks.push({ id, text: JSON.stringify(texts) });
    }
    return chunks;
}

// ---- Apply ----

function applyTranslation(msg) {
    const { chunkId, translation, error, progress } = msg;
    const batch = nodeMap.get(chunkId);
    if (!batch || !Array.isArray(batch)) return;

    isApplyingTranslation = true;

    if (error) {
        batch.forEach(n => { if (n.parentElement) n.parentElement.style.removeProperty("opacity"); });
    } else if (translation) {
        // Parse JSON array response
        let parts;
        try {
            parts = JSON.parse(translation);
        } catch {
            // Fallback: try to extract array from response
            const match = translation.match(/\[[\s\S]*\]/);
            if (match) {
                try { parts = JSON.parse(match[0]); } catch { parts = null; }
            }
        }

        if (Array.isArray(parts)) {
            batch.forEach((node, i) => {
                if (i < parts.length && parts[i]) {
                    node.textContent = String(parts[i]);
                }
                if (node.parentElement) {
                    node.parentElement.style.removeProperty("opacity");
                    node.parentElement.setAttribute("data-vox-done", "1");
                }
                translatedNodes.add(node);
            });
        } else {
            // Last resort: single translation for single node
            if (batch.length === 1) {
                batch[0].textContent = translation.trim();
                translatedNodes.add(batch[0]);
            }
            batch.forEach(n => { if (n.parentElement) n.parentElement.style.removeProperty("opacity"); });
        }
    }

    isApplyingTranslation = false;

    if (progress) {
        browser.runtime.sendMessage({ action: "progressUpdate", ...progress });
        if (progress.current >= progress.total && !mutationObserver) startObserver();
    }
}

// ---- Restore ----

function restorePage() {
    stopObserver();
    clearDomainAutoTranslate();
    isApplyingTranslation = true;
    for (const [, batch] of nodeMap) {
        (Array.isArray(batch) ? batch : [batch]).forEach(node => {
            if (node._voxOriginal) { node.textContent = node._voxOriginal; delete node._voxOriginal; }
            if (node.parentElement) {
                node.parentElement.style.removeProperty("opacity");
                node.parentElement.removeAttribute("data-vox-done");
            }
        });
    }
    isApplyingTranslation = false;
    nodeMap.clear();
    isTranslated = false;
    clearCache();
}

// ---- MutationObserver ----

function startObserver() {
    if (mutationObserver) return;
    mutationObserver = new MutationObserver(() => {
        if (!isTranslated || isApplyingTranslation) return;
        if (pendingMutationTimer) clearTimeout(pendingMutationTimer);
        pendingMutationTimer = setTimeout(() => {
            const newNodes = collectTextNodes();
            if (!newNodes.length) return;
            console.log("[Vox content] New nodes:", newNodes.length);
            const chunks = buildChunks(newNodes);
            browser.runtime.sendMessage({ action: "translateChunks", chunks, targetLanguage: currentLanguage });
        }, 1000);
    });
    mutationObserver.observe(document.body, { childList: true, subtree: true });
    console.log("[Vox content] Observer started");
}

function stopObserver() {
    if (mutationObserver) { mutationObserver.disconnect(); mutationObserver = null; }
    if (pendingMutationTimer) { clearTimeout(pendingMutationTimer); pendingMutationTimer = null; }
}

// ---- Cache / Domain ----

const CACHE_PREFIX = "vox-cache-";
function getCacheKey() { return CACHE_PREFIX + window.location.href; }
function clearCache() { try { localStorage.removeItem(getCacheKey()); } catch {} }

const DOMAIN_KEY = "vox-auto-translate-domain";
function setDomainAutoTranslate(lang) {
    try { localStorage.setItem(DOMAIN_KEY, JSON.stringify({ domain: location.hostname, language: lang, timestamp: Date.now() })); } catch {}
}
function clearDomainAutoTranslate() { try { localStorage.removeItem(DOMAIN_KEY); } catch {} }
function checkAutoTranslate() {
    try {
        const d = JSON.parse(localStorage.getItem(DOMAIN_KEY));
        if (d?.domain === location.hostname && Date.now() - d.timestamp < 7200000) {
            setTimeout(() => translatePage(d.language), 500);
        } else { localStorage.removeItem(DOMAIN_KEY); }
    } catch {}
}

} // end guard
