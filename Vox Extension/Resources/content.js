// Content script — extracts TEXT NODES, sends for translation, replaces text
if (window._voxLoaded) { /* already loaded */ } else {
window._voxLoaded = true;

const VOX_ATTR = "data-vox-original";
const VOX_ID_ATTR = "data-vox-id";
const CACHE_PREFIX = "vox-cache-";

let isTranslated = false;
let currentLanguage = "Auto";

// Map of vox-id -> array of text nodes
const nodeMap = new Map();
// Set of already-translated text nodes (to avoid re-translating)
let translatedNodes = new WeakSet();
let nodeIdCounter = 0;
let mutationObserver = null;
let pendingMutationTimer = null;
let isApplyingTranslation = false; // guard against self-triggered mutations

console.log("[Vox content] Content script loaded on:", window.location.href);

// Check if this domain is in auto-translate mode
checkAutoTranslate();

// Watch for SPA navigation (pushState / replaceState / popstate)
let lastUrl = window.location.href;

const origPushState = history.pushState;
history.pushState = function(...args) {
    origPushState.apply(this, args);
    onUrlChange();
};
const origReplaceState = history.replaceState;
history.replaceState = function(...args) {
    origReplaceState.apply(this, args);
    onUrlChange();
};
window.addEventListener("popstate", () => onUrlChange());

function onUrlChange() {
    const newUrl = window.location.href;
    if (newUrl === lastUrl) return;
    console.log("[Vox content] URL changed:", newUrl);
    lastUrl = newUrl;

    // Reset state for new page
    isTranslated = false;
    stopMutationObserver();
    nodeMap.clear();
    translatedNodes = new WeakSet();
    nodeIdCounter = 0;

    // Re-check auto-translate after DOM settles
    setTimeout(() => checkAutoTranslate(), 800);
}

browser.runtime.onMessage.addListener((message, sender, sendResponse) => {
    console.log("[Vox content] Received message:", message.action);
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

// Icon font detection
const ICON_CLASSES = /material-icons|fa\b|fa-|fas\b|far\b|fab\b|fal\b|glyphicon|bi\b|bi-/i;

function isIconNode(node) {
    const parent = node.parentElement;
    if (!parent) return false;
    const tag = parent.tagName.toLowerCase();
    // <i> with icon classes or short lowercase-underscore text
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

function shouldSkipParent(el) {
    const tag = el.tagName.toLowerCase();
    return ["script", "style", "noscript", "svg", "code", "pre", "textarea", "input", "select", "canvas", "iframe", "video", "audio"].includes(tag);
}

function collectTextNodes() {
    const textNodes = [];
    const walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_TEXT,
        {
            acceptNode(node) {
                // Skip empty/whitespace-only
                const text = node.textContent.trim();
                if (text.length < 2) return NodeFilter.FILTER_REJECT;
                // Skip pure numbers/symbols
                if (/^[\d\s.,;:!?%$€£¥+\-*/=()[\]{}@#&|<>]+$/.test(text)) return NodeFilter.FILTER_REJECT;
                // Skip icon font text
                if (isIconNode(node)) return NodeFilter.FILTER_REJECT;
                // Skip if parent is script/style/etc
                let parent = node.parentElement;
                while (parent && parent !== document.body) {
                    if (shouldSkipParent(parent)) return NodeFilter.FILTER_REJECT;
                    parent = parent.parentElement;
                }
                // Note: NOT skipping offsetParent===null — hidden menus/dropdowns need translation too
                return NodeFilter.FILTER_ACCEPT;
            }
        }
    );

    let n;
    while (n = walker.nextNode()) {
        // Skip already translated nodes
        if (translatedNodes.has(n)) continue;
        textNodes.push(n);
    }
    return textNodes;
}

function translatePage(targetLanguage) {
    currentLanguage = targetLanguage || "Auto";
    nodeMap.clear();
    nodeIdCounter = 0;

    // Remember: auto-translate this domain
    setDomainAutoTranslate(currentLanguage);

    const textNodes = collectTextNodes();
    console.log("[Vox content] Found text nodes:", textNodes.length);
    if (textNodes.length === 0) return;

    isTranslated = true;

    // Group text nodes into chunks (max 20 nodes or 300 words per chunk)
    const chunks = [];
    let currentChunk = [];
    let currentWordCount = 0;
    const MAX_WORDS = 300;
    const MAX_NODES = 20;

    for (const textNode of textNodes) {
        const text = textNode.textContent.trim();
        const words = text.split(/\s+/).length;

        if ((currentWordCount + words > MAX_WORDS || currentChunk.length >= MAX_NODES) && currentChunk.length > 0) {
            chunks.push(flushChunk(currentChunk));
            currentChunk = [];
            currentWordCount = 0;
        }
        currentChunk.push(textNode);
        currentWordCount += words;
    }
    if (currentChunk.length > 0) {
        chunks.push(flushChunk(currentChunk));
    }

    console.log("[Vox content] Created chunks:", chunks.length);

    sendChunksForTranslation(chunks);
}

function sendChunksForTranslation(chunks) {
    if (chunks.length === 0) return;
    console.log("[Vox content] Sending", chunks.length, "chunks for translation");
    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: currentLanguage
    });
}

function flushChunk(textNodes) {
    const id = `vox-${nodeIdCounter++}`;
    const texts = [];

    for (const node of textNodes) {
        // Store original text
        const original = node.textContent;
        texts.push(original.trim());

        // Mark parent element for visual feedback
        const parent = node.parentElement;
        if (parent) {
            parent.style.opacity = "0.5";
        }
    }

    // Store node references for later replacement
    nodeMap.set(id, { nodes: [...textNodes], originals: texts.map((_, i) => textNodes[i].textContent) });

    return { id, text: texts.join("\n---VOX_SEP---\n") };
}

function applyTranslation(message) {
    const { chunkId, translation, error, progress } = message;
    console.log("[Vox content] applyTranslation:", { chunkId, hasTranslation: !!translation, error });

    const entry = nodeMap.get(chunkId);
    if (!entry) return;

    if (error) {
        // Restore opacity on error
        entry.nodes.forEach(n => {
            if (n.parentElement) n.parentElement.style.removeProperty("opacity");
        });
        return;
    }

    if (translation) {
        const parts = translation.split("\n---VOX_SEP---\n");
        const translatedParts = parts.length === entry.nodes.length ? parts : translation.split("\n\n");

        isApplyingTranslation = true;
        entry.nodes.forEach((node, i) => {
            if (!node._voxOriginal) {
                node._voxOriginal = node.textContent;
            }
            if (i < translatedParts.length && translatedParts[i].trim()) {
                node.textContent = translatedParts[i].trim();
            }
            if (node.parentElement) {
                node.parentElement.style.removeProperty("opacity");
            }
            translatedNodes.add(node);
        });
        isApplyingTranslation = false;

        // Cache
        saveToCache(chunkId, translation);
    }

    if (progress) {
        browser.runtime.sendMessage({ action: "progressUpdate", ...progress });
        // Start observer after initial translation completes
        if (progress.current >= progress.total && !mutationObserver) {
            startMutationObserver();
        }
    }
}

// MARK: - MutationObserver (auto-translate new content)

function startMutationObserver() {
    if (mutationObserver) return; // already running

    mutationObserver = new MutationObserver((mutations) => {
        if (!isTranslated || isApplyingTranslation) return;

        // Debounce: wait for DOM to settle before scanning
        if (pendingMutationTimer) clearTimeout(pendingMutationTimer);
        pendingMutationTimer = setTimeout(() => {
            translateNewNodes();
        }, 500);
    });

    mutationObserver.observe(document.body, {
        childList: true,
        subtree: true,
        characterData: true
    });
    console.log("[Vox content] MutationObserver started — watching for new content");
}

function stopMutationObserver() {
    if (mutationObserver) {
        mutationObserver.disconnect();
        mutationObserver = null;
    }
    if (pendingMutationTimer) {
        clearTimeout(pendingMutationTimer);
        pendingMutationTimer = null;
    }
}

function translateNewNodes() {
    const newNodes = collectTextNodes(); // already skips translatedNodes
    if (newNodes.length === 0) return;

    console.log("[Vox content] Found", newNodes.length, "new text nodes to translate");

    const chunks = [];
    let currentChunk = [];
    let currentWordCount = 0;
    const MAX_WORDS = 300;
    const MAX_NODES = 20;

    for (const textNode of newNodes) {
        const words = textNode.textContent.trim().split(/\s+/).length;
        if ((currentWordCount + words > MAX_WORDS || currentChunk.length >= MAX_NODES) && currentChunk.length > 0) {
            chunks.push(flushChunk(currentChunk));
            currentChunk = [];
            currentWordCount = 0;
        }
        currentChunk.push(textNode);
        currentWordCount += words;
    }
    if (currentChunk.length > 0) {
        chunks.push(flushChunk(currentChunk));
    }

    sendChunksForTranslation(chunks);
}

function restorePage() {
    stopMutationObserver();
    clearDomainAutoTranslate();
    for (const [id, entry] of nodeMap) {
        entry.nodes.forEach((node, i) => {
            if (node._voxOriginal) {
                node.textContent = node._voxOriginal;
                delete node._voxOriginal;
            }
            if (node.parentElement) {
                node.parentElement.style.removeProperty("opacity");
            }
        });
    }
    nodeMap.clear();
    isTranslated = false;
    clearCache();
}

// MARK: - Cache

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

// MARK: - Auto-translate domain

const DOMAIN_KEY = "vox-auto-translate-domain";

function setDomainAutoTranslate(language) {
    try {
        const data = { domain: window.location.hostname, language, timestamp: Date.now() };
        localStorage.setItem(DOMAIN_KEY, JSON.stringify(data));
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
        // Same domain and within 2 hours
        if (data.domain === window.location.hostname && Date.now() - data.timestamp < 2 * 60 * 60 * 1000) {
            console.log("[Vox content] Auto-translating (domain mode):", data.language);
            // Small delay to let page finish rendering
            setTimeout(() => {
                translatePage(data.language);
            }, 500);
        } else {
            localStorage.removeItem(DOMAIN_KEY);
        }
    } catch (e) {}
}

} // end if !_voxLoaded
