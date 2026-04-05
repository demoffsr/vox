// Content script — extracts page text, sends for translation, replaces with result

const VOX_ATTR = "data-vox-original";
const VOX_ID_ATTR = "data-vox-id";
const CACHE_PREFIX = "vox-cache-";

let isTranslated = false;
let chunkCounter = 0;
let currentLanguage = "Auto";

console.log("[Vox content] Content script loaded on:", window.location.href);

// Check if we have a cached translation for this page
checkCache();

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
            sendResponse({ isTranslated, hasCache: hasCache() });
            break;
    }
});

function translatePage(targetLanguage) {
    currentLanguage = targetLanguage || "Auto";
    const chunks = extractTextChunks();
    console.log("[Vox content] Extracted chunks:", chunks.length);
    if (chunks.length === 0) return;

    isTranslated = true;

    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: currentLanguage
    });
}

function restorePage() {
    const elements = document.querySelectorAll(`[${VOX_ATTR}]`);
    elements.forEach(el => {
        el.textContent = el.getAttribute(VOX_ATTR);
        el.removeAttribute(VOX_ATTR);
        el.removeAttribute(VOX_ID_ATTR);
        el.style.removeProperty("opacity");
    });
    isTranslated = false;
}

// Icon font class patterns to skip
const ICON_CLASSES = /material-icons|fa\b|fa-|fas\b|far\b|fab\b|fal\b|icon|glyphicon|bi\b|bi-/i;
const ICON_TAGS = new Set(["i", "mat-icon", "ion-icon"]);

function isIconElement(node) {
    const tag = node.tagName.toLowerCase();
    // Skip <i> tags that are likely icons (short content or icon classes)
    if (ICON_TAGS.has(tag)) {
        const text = node.textContent.trim();
        // Icon fonts typically have short text like "arrow_drop_down", "close", "menu"
        if (text.length < 30 && /^[a-z_]+$/.test(text)) return true;
        if (ICON_CLASSES.test(node.className)) return true;
    }
    if (ICON_CLASSES.test(node.className)) return true;
    // Check computed font-family for icon fonts
    try {
        const font = getComputedStyle(node).fontFamily.toLowerCase();
        if (font.includes("material") || font.includes("fontawesome") || font.includes("icon")) return true;
    } catch (e) {}
    return false;
}

function extractTextChunks() {
    const chunks = [];
    const walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_ELEMENT,
        {
            acceptNode(node) {
                const tag = node.tagName.toLowerCase();
                // Skip non-content elements
                if (["script", "style", "noscript", "svg", "code", "pre", "textarea", "input", "select", "button", "img", "video", "audio", "canvas", "iframe"].includes(tag)) {
                    return NodeFilter.FILTER_REJECT;
                }
                // Skip hidden elements
                if (node.offsetParent === null && tag !== "body" && tag !== "html") {
                    return NodeFilter.FILTER_REJECT;
                }
                // Skip icon elements
                if (isIconElement(node)) {
                    return NodeFilter.FILTER_REJECT;
                }
                // Skip elements with aria-hidden (often icons/decorative)
                if (node.getAttribute("aria-hidden") === "true") {
                    return NodeFilter.FILTER_REJECT;
                }
                return NodeFilter.FILTER_ACCEPT;
            }
        }
    );

    const textElements = [];
    let node;
    while (node = walker.nextNode()) {
        const directText = getDirectText(node);
        const trimmed = directText.trim();
        // Skip very short text, pure numbers, or icon-like text
        if (trimmed.length < 3) continue;
        if (/^[\d\s.,;:!?%$€£¥+\-*/=()[\]{}]+$/.test(trimmed)) continue;
        if (/^[a-z_]+$/.test(trimmed) && trimmed.length < 30) continue; // icon font text
        textElements.push(node);
    }

    let currentChunk = [];
    let currentWordCount = 0;
    const MAX_WORDS = 500;

    for (const el of textElements) {
        const text = el.textContent.trim();
        const wordCount = text.split(/\s+/).length;

        if (currentWordCount + wordCount > MAX_WORDS && currentChunk.length > 0) {
            flushChunk(chunks, currentChunk);
            currentChunk = [];
            currentWordCount = 0;
        }

        currentChunk.push(el);
        currentWordCount += wordCount;
    }

    if (currentChunk.length > 0) {
        flushChunk(chunks, currentChunk);
    }

    return chunks;
}

function flushChunk(chunks, elements) {
    const id = `vox-chunk-${chunkCounter++}`;
    const combinedText = elements.map(e => e.textContent.trim()).join("\n\n");
    elements.forEach(e => {
        e.setAttribute(VOX_ID_ATTR, id);
        e.setAttribute(VOX_ATTR, e.textContent);
        e.style.opacity = "0.5";
    });
    chunks.push({ id, text: combinedText, elementCount: elements.length });
}

function applyTranslation(message) {
    const { chunkId, translation, error, progress } = message;
    console.log("[Vox content] applyTranslation:", { chunkId, hasTranslation: !!translation, error, progress });
    if (!chunkId) return;

    const elements = document.querySelectorAll(`[${VOX_ID_ATTR}="${chunkId}"]`);
    if (elements.length === 0) return;

    if (error) {
        elements.forEach(el => { el.style.opacity = "1"; });
        return;
    }

    if (translation) {
        const translatedParts = translation.split("\n\n");
        elements.forEach((el, i) => {
            if (i < translatedParts.length && translatedParts[i].trim()) {
                el.textContent = translatedParts[i];
            }
            el.style.opacity = "1";
        });

        // Save to cache
        saveToCache(chunkId, translation);
    }

    if (progress) {
        browser.runtime.sendMessage({
            action: "progressUpdate",
            ...progress
        });
    }
}

function getDirectText(node) {
    let text = "";
    for (const child of node.childNodes) {
        if (child.nodeType === Node.TEXT_NODE) {
            text += child.textContent;
        }
    }
    return text;
}

// MARK: - Cache

function getCacheKey() {
    return CACHE_PREFIX + window.location.href;
}

function hasCache() {
    try {
        return !!localStorage.getItem(getCacheKey());
    } catch { return false; }
}

function saveToCache(chunkId, translation) {
    try {
        const key = getCacheKey();
        const cache = JSON.parse(localStorage.getItem(key) || "{}");
        cache.language = currentLanguage;
        cache.timestamp = Date.now();
        cache.chunks = cache.chunks || {};
        cache.chunks[chunkId] = translation;
        localStorage.setItem(key, JSON.stringify(cache));
    } catch (e) {
        console.warn("[Vox content] Cache save failed:", e);
    }
}

function checkCache() {
    try {
        const key = getCacheKey();
        const cached = localStorage.getItem(key);
        if (!cached) return;

        const data = JSON.parse(cached);
        // Cache expires after 24 hours
        if (Date.now() - data.timestamp > 24 * 60 * 60 * 1000) {
            localStorage.removeItem(key);
            return;
        }

        console.log("[Vox content] Found cached translation, language:", data.language);
        // Don't auto-apply, but let popup know cache exists
    } catch (e) {}
}

function applyCachedTranslation() {
    try {
        const data = JSON.parse(localStorage.getItem(getCacheKey()));
        if (!data?.chunks) return false;

        const elements = extractTextChunks();
        for (const chunk of elements) {
            const cached = data.chunks[chunk.id];
            if (cached) {
                const els = document.querySelectorAll(`[${VOX_ID_ATTR}="${chunk.id}"]`);
                const parts = cached.split("\n\n");
                els.forEach((el, i) => {
                    if (i < parts.length && parts[i].trim()) {
                        el.textContent = parts[i];
                    }
                    el.style.opacity = "1";
                });
            }
        }
        isTranslated = true;
        currentLanguage = data.language;
        return true;
    } catch (e) {
        console.warn("[Vox content] Cache apply failed:", e);
        return false;
    }
}
