// Content script — 1 text node = 1 translation request. No separators, no merging.
if (window._voxLoaded) { /* already loaded */ } else {
window._voxLoaded = true;

let isTranslated = false;
let currentLanguage = "Auto";
let translatedNodes = new WeakSet();
let mutationObserver = null;
let pendingMutationTimer = null;
let isApplyingTranslation = false;

// node id -> { node, original }
const nodeMap = new Map();
let nodeIdCounter = 0;

console.log("[Vox content] Content script loaded on:", window.location.href);

checkAutoTranslate();

// SPA navigation detection
let lastUrl = window.location.href;
const origPushState = history.pushState;
history.pushState = function(...args) { origPushState.apply(this, args); onUrlChange(); };
const origReplaceState = history.replaceState;
history.replaceState = function(...args) { origReplaceState.apply(this, args); onUrlChange(); };
window.addEventListener("popstate", () => onUrlChange());

function onUrlChange() {
    const newUrl = window.location.href;
    if (newUrl === lastUrl) return;
    console.log("[Vox content] URL changed:", newUrl);
    lastUrl = newUrl;
    isTranslated = false;
    stopMutationObserver();
    nodeMap.clear();
    translatedNodes = new WeakSet();
    nodeIdCounter = 0;
    setTimeout(() => checkAutoTranslate(), 800);
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    switch (message.action) {
        case "translatePage":
            translatePage(message.targetLanguage);
            break;
        case "restorePage":
            restorePage();
            break;
        case "translationResult":
            applyTranslation(message);
            break;
        case "getStatus":
            sendResponse({ isTranslated });
            break;
    }
});

// ---- Icon / skip detection ----

const ICON_CLASSES = /material-icons|fa\b|fa-|fas\b|far\b|fab\b|fal\b|glyphicon|bi\b|bi-/i;

function isIconNode(node) {
    const parent = node.parentElement;
    if (!parent) return false;
    const tag = parent.tagName.toLowerCase();
    if (tag === "i" || tag === "mat-icon" || tag === "ion-icon") {
        if (ICON_CLASSES.test(parent.className)) return true;
        const t = node.textContent.trim();
        if (t.length < 30 && /^[a-z_]+$/.test(t)) return true;
    }
    if (ICON_CLASSES.test(parent.className)) return true;
    if (parent.getAttribute("aria-hidden") === "true") return true;
    try {
        const font = getComputedStyle(parent).fontFamily.toLowerCase();
        if (font.includes("material") || font.includes("fontawesome") || font.includes("icon")) return true;
    } catch (e) {}
    return false;
}

const SKIP_TAGS = new Set(["script", "style", "noscript", "svg", "code", "pre", "textarea", "input", "select", "canvas", "iframe", "video", "audio"]);
const SKIP_ROLES = new Set(["slider", "toolbar", "menubar", "menu", "menuitem", "menuitemcheckbox", "dialog", "alertdialog"]);

function shouldSkipParent(el) {
    const tag = el.tagName.toLowerCase();
    if (SKIP_TAGS.has(tag)) return true;
    const cls = el.className?.toString?.() || "";
    if (/vjs|video-js|plyr|mejs|jw-|html5-video/i.test(cls)) return true;
    const ariaLabel = el.getAttribute("aria-label") || "";
    if (/video player|modal|caption settings|dialog/i.test(ariaLabel)) return true;
    const role = el.getAttribute("role") || "";
    if (SKIP_ROLES.has(role)) return true;
    if (tag === "dialog") return true;
    return false;
}

// ---- Collect text nodes ----

function collectTextNodes() {
    const textNodes = [];
    const walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_TEXT,
        {
            acceptNode(node) {
                const text = node.textContent.trim();
                if (text.length < 2) return NodeFilter.FILTER_REJECT;
                if (/^[\d\s.,;:!?%$€£¥+\-*/=()[\]{}@#&|<>]+$/.test(text)) return NodeFilter.FILTER_REJECT;
                if (isIconNode(node)) return NodeFilter.FILTER_REJECT;
                let parent = node.parentElement;
                while (parent && parent !== document.body) {
                    if (shouldSkipParent(parent)) return NodeFilter.FILTER_REJECT;
                    parent = parent.parentElement;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        }
    );
    let n;
    while (n = walker.nextNode()) {
        if (!translatedNodes.has(n)) textNodes.push(n);
    }
    return textNodes;
}

// ---- Translate page ----

function translatePage(targetLanguage) {
    currentLanguage = targetLanguage || "Auto";
    nodeMap.clear();
    nodeIdCounter = 0;
    setDomainAutoTranslate(currentLanguage);

    const textNodes = collectTextNodes();
    console.log("[Vox content] Found text nodes:", textNodes.length);
    if (textNodes.length === 0) return;
    isTranslated = true;

    // 1 node = 1 chunk. Simple, reliable, no separator issues.
    const chunks = [];
    for (const node of textNodes) {
        const id = `vox-${nodeIdCounter++}`;
        const text = node.textContent.trim();
        node._voxOriginal = node.textContent;
        if (node.parentElement) node.parentElement.style.opacity = "0.5";
        nodeMap.set(id, node);
        chunks.push({ id, text });
    }

    console.log("[Vox content] Sending", chunks.length, "individual nodes for translation");
    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: currentLanguage
    });
}

// ---- Apply single translation ----

function applyTranslation(message) {
    const { chunkId, translation, error, progress } = message;

    const node = nodeMap.get(chunkId);
    if (!node) return;

    isApplyingTranslation = true;

    if (error) {
        if (node.parentElement) node.parentElement.style.removeProperty("opacity");
    } else if (translation) {
        node.textContent = translation.trim();
        if (node.parentElement) node.parentElement.style.removeProperty("opacity");
        translatedNodes.add(node);
    }

    isApplyingTranslation = false;

    if (progress) {
        browser.runtime.sendMessage({ action: "progressUpdate", ...progress });
        if (progress.current >= progress.total && !mutationObserver) {
            startMutationObserver();
        }
    }
}

// ---- Restore ----

function restorePage() {
    stopMutationObserver();
    clearDomainAutoTranslate();
    for (const [id, node] of nodeMap) {
        if (node._voxOriginal) {
            node.textContent = node._voxOriginal;
            delete node._voxOriginal;
        }
        if (node.parentElement) node.parentElement.style.removeProperty("opacity");
    }
    nodeMap.clear();
    isTranslated = false;
    clearCache();
}

// ---- MutationObserver ----

function startMutationObserver() {
    if (mutationObserver) return;
    mutationObserver = new MutationObserver(() => {
        if (!isTranslated || isApplyingTranslation) return;
        if (pendingMutationTimer) clearTimeout(pendingMutationTimer);
        pendingMutationTimer = setTimeout(() => translateNewNodes(), 500);
    });
    mutationObserver.observe(document.body, { childList: true, subtree: true, characterData: true });
    console.log("[Vox content] MutationObserver started");
}

function stopMutationObserver() {
    if (mutationObserver) { mutationObserver.disconnect(); mutationObserver = null; }
    if (pendingMutationTimer) { clearTimeout(pendingMutationTimer); pendingMutationTimer = null; }
}

function translateNewNodes() {
    const newNodes = collectTextNodes();
    if (newNodes.length === 0) return;
    console.log("[Vox content] Found", newNodes.length, "new nodes");

    const chunks = [];
    for (const node of newNodes) {
        const id = `vox-${nodeIdCounter++}`;
        node._voxOriginal = node.textContent;
        if (node.parentElement) node.parentElement.style.opacity = "0.5";
        nodeMap.set(id, node);
        chunks.push({ id, text: node.textContent.trim() });
    }
    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: currentLanguage
    });
}

// ---- Cache ----

const CACHE_PREFIX = "vox-cache-";
function getCacheKey() { return CACHE_PREFIX + window.location.href; }
function saveToCache(chunkId, translation) {
    try {
        const key = getCacheKey();
        const cache = JSON.parse(localStorage.getItem(key) || "{}");
        cache.language = currentLanguage;
        cache.timestamp = Date.now();
        cache.chunks = cache.chunks || {};
        cache.chunks[chunkId] = translation;
        localStorage.setItem(key, JSON.stringify(cache));
    } catch (e) {}
}
function clearCache() {
    try { localStorage.removeItem(getCacheKey()); } catch (e) {}
}

// ---- Auto-translate domain ----

const DOMAIN_KEY = "vox-auto-translate-domain";
function setDomainAutoTranslate(language) {
    try {
        localStorage.setItem(DOMAIN_KEY, JSON.stringify({ domain: window.location.hostname, language, timestamp: Date.now() }));
    } catch (e) {}
}
function clearDomainAutoTranslate() {
    try { localStorage.removeItem(DOMAIN_KEY); } catch (e) {}
}
function checkAutoTranslate() {
    try {
        const raw = localStorage.getItem(DOMAIN_KEY);
        if (!raw) return;
        const data = JSON.parse(raw);
        if (data.domain === window.location.hostname && Date.now() - data.timestamp < 2 * 60 * 60 * 1000) {
            console.log("[Vox content] Auto-translating:", data.language);
            setTimeout(() => translatePage(data.language), 500);
        } else {
            localStorage.removeItem(DOMAIN_KEY);
        }
    } catch (e) {}
}

} // end if !_voxLoaded
