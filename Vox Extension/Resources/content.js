// Content script — batch translation via JSON array format
if (window._voxLoaded) { /* already loaded */ } else {
window._voxLoaded = true;

let translationActive = false;
let currentLanguage = "Auto";
let isTranslated = false;
let translatedNodes = new WeakSet();
let mutationObserver = null;
let pendingMutationTimer = null;
let isApplyingTranslation = false;

const nodeMap = new Map();
let nodeIdCounter = 0;

const VOX_STATE_KEY = "vox-translation-state";

console.log("[Vox content] Content script loaded on:", window.location.href);
checkSavedState();

// ---- SPA navigation ----

let lastUrl = window.location.href;
const origPush = history.pushState;
history.pushState = function(...a) { origPush.apply(this, a); onUrlChange(); };
const origReplace = history.replaceState;
history.replaceState = function(...a) { origReplace.apply(this, a); onUrlChange(); };
window.addEventListener("popstate", () => onUrlChange());
window.addEventListener("hashchange", () => onUrlChange());
window.addEventListener("pageshow", (e) => { if (e.persisted) checkSavedState(); });

// Fallback: poll URL for SPAs that don't use pushState (e.g. LinkedIn)
setInterval(() => {
    if (window.location.href !== lastUrl) onUrlChange();
}, 1000);

// Re-translate lazy-loaded content on tab re-focus
document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible" && translationActive && isTranslated) {
        if (pendingMutationTimer) clearTimeout(pendingMutationTimer);
        pendingMutationTimer = setTimeout(() => {
            const newNodes = collectTextNodes();
            if (!newNodes.length) return;
            const chunks = buildChunks(newNodes);
            browser.runtime.sendMessage({ action: "translateChunks", chunks, targetLanguage: currentLanguage });
        }, 500);
    }
});

function onUrlChange() {
    if (window.location.href === lastUrl) return;
    console.log("[Vox content] URL changed:", lastUrl, "→", window.location.href);
    lastUrl = window.location.href;

    if (!translationActive) return;

    // Reset tracking for new page (SPA replaces content, no need to restore text)
    document.querySelectorAll("[data-vox-done]").forEach(el => el.removeAttribute("data-vox-done"));
    stopObserver();
    nodeMap.clear();
    translatedNodes = new WeakSet();
    nodeIdCounter = 0;
    isTranslated = false;

    // Translate new page with retry (DOM may not be ready yet)
    translateWithRetry(currentLanguage, 0);
}

function translateWithRetry(language, attempt) {
    const delay = attempt === 0 ? 300 : 800;
    setTimeout(() => {
        if (!translationActive) return;
        console.log("[Vox content] Translate attempt", attempt + 1, "on", window.location.href);
        translatePage(language);
        if (!isTranslated && attempt < 5) {
            translateWithRetry(language, attempt + 1);
        }
    }, delay);
}

// ---- Enable / Disable ----

function enableTranslation(language) {
    currentLanguage = language || "Auto";
    translationActive = true;
    console.log("[Vox content] Translation enabled:", currentLanguage);
    saveState();
    translateWithRetry(currentLanguage, 0);
}

function disableTranslation() {
    console.log("[Vox content] Translation disabled");
    translationActive = false;
    removeState();
    stopObserver();

    // Restore original text
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
    translatedNodes = new WeakSet();
    isTranslated = false;
}

function saveState() {
    try { localStorage.setItem(VOX_STATE_KEY, JSON.stringify({ domain: location.hostname, language: currentLanguage, enabled: true })); } catch {}
}

function removeState() {
    try { localStorage.removeItem(VOX_STATE_KEY); } catch {}
}

function checkSavedState() {
    try {
        const s = JSON.parse(localStorage.getItem(VOX_STATE_KEY));
        if (s?.enabled && s?.domain === location.hostname) {
            enableTranslation(s.language);
        }
    } catch {}
}

// ---- Messages ----

browser.runtime.onMessage.addListener((msg, sender, sendResponse) => {
    if (msg.action === "enableTranslation") enableTranslation(msg.targetLanguage);
    else if (msg.action === "disableTranslation") disableTranslation();
    else if (msg.action === "translatePage") enableTranslation(msg.targetLanguage); // legacy compat
    else if (msg.action === "restorePage") disableTranslation(); // legacy compat
    else if (msg.action === "translationResult") applyTranslation(msg);
    else if (msg.action === "getStatus") sendResponse({ translationActive, language: currentLanguage });
});

// ---- Skip logic ----

const ICON_RE = /material-icons|fa\b|fa-|fas\b|far\b|fab\b|fal\b|glyphicon|bi\b|bi-/i;
const SKIP_TAGS = new Set(["script","style","noscript","svg","code","pre","textarea","input","select","canvas","iframe","video","audio"]);
const SKIP_ROLES = new Set(["slider","toolbar","menubar"]);
const DYNAMIC_ROLES = new Set(["dialog","alertdialog","menu","menuitem","menuitemcheckbox"]);

function isActionOnlyContainer(el) {
    const role = el.getAttribute("role") || "";
    const tag = el.tagName.toLowerCase();
    if (!DYNAMIC_ROLES.has(role) && tag !== "dialog") return false;
    if (role === "dialog" || role === "alertdialog" || tag === "dialog") return false;
    const textLen = el.textContent.trim().length;
    if (textLen > 200) return false;
    const contentTags = el.querySelectorAll("p, h1, h2, h3, h4, h5, h6, article, blockquote");
    if (contentTags.length > 0) return false;
    if ((role === "menu" || role === "menuitem" || role === "menuitemcheckbox") && textLen < 40) return true;
    return false;
}

function shouldSkip(node) {
    const text = node.textContent.trim();
    if (text.length < 2) return true;
    if (/^[\d\s.,;:!?%$€£¥+\-*/=()[\]{}@#&|<>]+$/.test(text)) return true;

    const parent = node.parentElement;
    if (!parent) return true;
    if (parent.hasAttribute("data-vox-done")) return true;

    const ptag = parent.tagName.toLowerCase();
    if ((ptag === "i" || ptag === "mat-icon") && (ICON_RE.test(parent.className) || (text.length < 30 && /^[a-z_]+$/.test(text)))) return true;
    if (ICON_RE.test(parent.className)) return true;
    if (parent.getAttribute("aria-hidden") === "true") return true;

    let el = parent;
    while (el && el !== document.body) {
        const tag = el.tagName.toLowerCase();
        if (SKIP_TAGS.has(tag)) return true;
        const cls = el.className?.toString?.() || "";
        if (/vjs|video-js|plyr|mejs|jw-/i.test(cls)) return true;
        const aria = el.getAttribute("aria-label") || "";
        if (/video player|caption/i.test(aria)) return true;
        const role = el.getAttribute("role") || "";
        if (SKIP_ROLES.has(role)) return true;
        if (isActionOnlyContainer(el)) return true;
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

const BATCH_SIZE = 30;

function translatePage(targetLanguage) {
    currentLanguage = targetLanguage || "Auto";

    let textNodes = collectTextNodes();
    console.log("[Vox content] Found text nodes:", textNodes.length);
    if (!textNodes.length) return;

    // Check cache — apply matching, send rest to API
    const cache = loadTranslationCache();
    if (cache && cache.language === currentLanguage) {
        const cached = [];
        const uncached = [];
        for (const node of textNodes) {
            const orig = node.textContent.trim();
            if (cache.translations[orig]) cached.push(node);
            else uncached.push(node);
        }
        if (cached.length > 0) {
            console.log("[Vox content] Cache: applying", cached.length, "cached,", uncached.length, "uncached");
            applyCachedTranslations(cached, cache.translations);
            if (!uncached.length) return;
            textNodes = uncached;
        }
    }

    isTranslated = true;
    const chunks = buildChunks(textNodes);
    console.log("[Vox content] Sending", chunks.length, "batches");
    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks, targetLanguage: currentLanguage
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
        let parts;
        try { parts = JSON.parse(translation); } catch {
            const match = translation.match(/\[[\s\S]*\]/);
            if (match) { try { parts = JSON.parse(match[0]); } catch { parts = null; } }
        }

        if (Array.isArray(parts)) {
            batch.forEach((node, i) => {
                if (i < parts.length && parts[i]) node.textContent = String(parts[i]);
                if (node.parentElement) {
                    node.parentElement.style.removeProperty("opacity");
                    node.parentElement.setAttribute("data-vox-done", "1");
                }
                translatedNodes.add(node);
            });
        } else {
            if (batch.length === 1) { batch[0].textContent = translation.trim(); translatedNodes.add(batch[0]); }
            batch.forEach(n => { if (n.parentElement) n.parentElement.style.removeProperty("opacity"); });
        }
    }

    isApplyingTranslation = false;

    if (progress) {
        browser.runtime.sendMessage({ action: "progressUpdate", ...progress });
        if (progress.current >= progress.total) {
            if (!mutationObserver) startObserver();
            saveTranslationCache();
        }
    }
}

// ---- MutationObserver ----

function startObserver() {
    if (mutationObserver) return;
    mutationObserver = new MutationObserver((mutations) => {
        if (!translationActive || isApplyingTranslation) return;
        let hasDialog = false;
        for (const m of mutations) {
            for (const node of m.addedNodes) {
                if (node.nodeType === 1) {
                    const tag = node.tagName?.toLowerCase();
                    const role = node.getAttribute?.("role") || "";
                    if (tag === "dialog" || role === "dialog" || role === "alertdialog") { hasDialog = true; break; }
                }
            }
            if (hasDialog) break;
        }
        if (pendingMutationTimer) clearTimeout(pendingMutationTimer);
        pendingMutationTimer = setTimeout(() => {
            const newNodes = collectTextNodes();
            if (!newNodes.length) return;
            console.log("[Vox content] New nodes:", newNodes.length);
            const chunks = buildChunks(newNodes);
            browser.runtime.sendMessage({ action: "translateChunks", chunks, targetLanguage: currentLanguage });
        }, hasDialog ? 300 : 1000);
    });
    mutationObserver.observe(document.body, { childList: true, subtree: true });
    console.log("[Vox content] Observer started");
}

function stopObserver() {
    if (mutationObserver) { mutationObserver.disconnect(); mutationObserver = null; }
    if (pendingMutationTimer) { clearTimeout(pendingMutationTimer); pendingMutationTimer = null; }
}

// ---- Cache ----

const CACHE_PREFIX = "vox-cache-";
const CACHE_TTL = 86400000;
const CACHE_MAX_ENTRIES = 500;
function getCacheKey() { return CACHE_PREFIX + window.location.href; }
function clearCache() { try { localStorage.removeItem(getCacheKey()); } catch {} }

function loadTranslationCache() {
    try {
        const raw = localStorage.getItem(getCacheKey());
        if (!raw) return null;
        const data = JSON.parse(raw);
        if (Date.now() - data.timestamp > CACHE_TTL) { localStorage.removeItem(getCacheKey()); return null; }
        return data;
    } catch { return null; }
}

function saveTranslationCache() {
    const existing = loadTranslationCache();
    const translations = (existing && existing.language === currentLanguage) ? { ...existing.translations } : {};
    let count = Object.keys(translations).length;
    for (const [, batch] of nodeMap) {
        for (const node of (Array.isArray(batch) ? batch : [batch])) {
            if (node._voxOriginal && node.textContent !== node._voxOriginal) {
                translations[node._voxOriginal.trim()] = node.textContent;
                if (++count >= CACHE_MAX_ENTRIES) break;
            }
        }
        if (count >= CACHE_MAX_ENTRIES) break;
    }
    if (!Object.keys(translations).length) return;
    try {
        localStorage.setItem(getCacheKey(), JSON.stringify({ timestamp: Date.now(), language: currentLanguage, translations }));
    } catch { evictOldCaches(); try { localStorage.setItem(getCacheKey(), JSON.stringify({ timestamp: Date.now(), language: currentLanguage, translations })); } catch {} }
}

function evictOldCaches() {
    const keys = [];
    for (let i = 0; i < localStorage.length; i++) {
        const k = localStorage.key(i);
        if (k && k.startsWith(CACHE_PREFIX)) {
            try { const d = JSON.parse(localStorage.getItem(k)); keys.push({ key: k, ts: d.timestamp || 0 }); }
            catch { keys.push({ key: k, ts: 0 }); }
        }
    }
    keys.sort((a, b) => a.ts - b.ts);
    const removeCount = Math.max(1, Math.floor(keys.length / 2));
    for (let i = 0; i < removeCount; i++) localStorage.removeItem(keys[i].key);
}

function applyCachedTranslations(textNodes, translations) {
    let applied = 0;
    isApplyingTranslation = true;
    for (const node of textNodes) {
        const original = node.textContent.trim();
        if (translations[original]) {
            node._voxOriginal = node.textContent;
            node.textContent = translations[original];
            if (node.parentElement) node.parentElement.setAttribute("data-vox-done", "1");
            translatedNodes.add(node);
            nodeMap.set(`vox-cache-${nodeIdCounter++}`, [node]);
            applied++;
        }
    }
    isApplyingTranslation = false;
    isTranslated = true;
    if (applied > 0) {
        console.log("[Vox content] Applied", applied, "cached translations");
        browser.runtime.sendMessage({ action: "progressUpdate", current: 1, total: 1 });
        startObserver();
    }
}

// ============================================================
// LIVE SUBTITLES — overlay + polling
// ============================================================

let _voxSubtitleActive = false;
let _voxSubtitleContainer = null;
let _voxSubtitleSpan = null;
let _voxLastSubtitleTimestamp = 0;
let _voxSubtitleFadeTimer = null;

function voxCreateSubtitleOverlay() {
    const player = document.querySelector('.html5-video-player');
    if (!player) return false;
    if (_voxSubtitleContainer && player.contains(_voxSubtitleContainer)) return true;
    _voxSubtitleContainer = document.createElement('div');
    _voxSubtitleContainer.className = 'vox-subtitle-container';
    _voxSubtitleContainer.setAttribute('style', 'position:absolute;bottom:60px;left:0;width:100%;text-align:center;z-index:9999;pointer-events:none;transition:opacity 0.3s ease');
    _voxSubtitleSpan = document.createElement('span');
    _voxSubtitleSpan.className = 'vox-subtitle';
    _voxSubtitleSpan.setAttribute('style', 'background:rgba(0,0,0,0.80);color:white;padding:6px 16px;border-radius:6px;font-size:20px;font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.4;display:inline-block;max-width:80%;text-shadow:0 1px 2px rgba(0,0,0,0.5)');
    _voxSubtitleContainer.appendChild(_voxSubtitleSpan);
    player.style.position = 'relative';
    player.appendChild(_voxSubtitleContainer);
    return true;
}

function voxShowSubtitle(text) {
    if (!_voxSubtitleSpan) return;
    _voxSubtitleSpan.textContent = text;
    _voxSubtitleContainer.style.opacity = '1';
    if (_voxSubtitleFadeTimer) clearTimeout(_voxSubtitleFadeTimer);
    _voxSubtitleFadeTimer = setTimeout(() => { if (_voxSubtitleContainer) _voxSubtitleContainer.style.opacity = '0'; }, 5000);
}

function voxRemoveSubtitleOverlay() {
    if (_voxSubtitleContainer) { _voxSubtitleContainer.remove(); _voxSubtitleContainer = null; _voxSubtitleSpan = null; }
    if (_voxSubtitleFadeTimer) { clearTimeout(_voxSubtitleFadeTimer); _voxSubtitleFadeTimer = null; }
}

async function voxPollSubtitles() {
    while (_voxSubtitleActive) {
        try {
            const response = await browser.runtime.sendMessage({ action: "getSubtitleUpdate" });
            if (response && response.text && response.timestamp > _voxLastSubtitleTimestamp) _voxLastSubtitleTimestamp = response.timestamp;
            if (response && response.status === "error") { voxStopSubtitles(); return; }
        } catch (e) { console.error("[Vox] Poll error:", e); }
        await new Promise(r => setTimeout(r, 150));
    }
}

function voxStartSubtitles() {
    if (_voxSubtitleActive) return;
    if (!voxCreateSubtitleOverlay()) {
        const video = document.querySelector('video');
        if (video) {
            const parent = video.closest('[class*="player"]') || video.parentElement;
            if (parent) {
                _voxSubtitleContainer = document.createElement('div');
                _voxSubtitleContainer.className = 'vox-subtitle-container';
                _voxSubtitleContainer.setAttribute('style', 'position:absolute;bottom:60px;left:0;width:100%;text-align:center;z-index:9999;pointer-events:none;transition:opacity 0.3s ease');
                _voxSubtitleSpan = document.createElement('span');
                _voxSubtitleSpan.className = 'vox-subtitle';
                _voxSubtitleSpan.setAttribute('style', 'background:rgba(0,0,0,0.80);color:white;padding:6px 16px;border-radius:6px;font-size:20px;font-family:-apple-system,BlinkMacSystemFont,sans-serif;line-height:1.4;display:inline-block;max-width:80%;text-shadow:0 1px 2px rgba(0,0,0,0.5)');
                _voxSubtitleContainer.appendChild(_voxSubtitleSpan);
                parent.style.position = 'relative';
                parent.appendChild(_voxSubtitleContainer);
            } else return;
        } else return;
    }
    _voxSubtitleActive = true;
    _voxLastSubtitleTimestamp = 0;
    voxPollSubtitles();
}

function voxStopSubtitles() { _voxSubtitleActive = false; voxRemoveSubtitleOverlay(); }

browser.runtime.onMessage.addListener((message) => {
    if (message.action === "startSubtitlesUI") voxStartSubtitles();
    if (message.action === "stopSubtitlesUI") voxStopSubtitles();
});

} // end guard
