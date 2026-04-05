// Content script — extracts page text, sends for translation, replaces with result

const VOX_ATTR = "data-vox-original";
const VOX_ID_ATTR = "data-vox-id";

let isTranslated = false;
let chunkCounter = 0;

console.log("[Vox content] Content script loaded on:", window.location.href);

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

function translatePage(targetLanguage) {
    const chunks = extractTextChunks();
    console.log("[Vox content] Extracted chunks:", chunks.length);
    if (chunks.length === 0) return;

    isTranslated = true;

    browser.runtime.sendMessage({
        action: "translateChunks",
        chunks: chunks,
        targetLanguage: targetLanguage || "Auto"
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

function extractTextChunks() {
    const chunks = [];
    const walker = document.createTreeWalker(
        document.body,
        NodeFilter.SHOW_ELEMENT,
        {
            acceptNode(node) {
                const tag = node.tagName.toLowerCase();
                if (["script", "style", "noscript", "svg", "code", "pre", "textarea", "input"].includes(tag)) {
                    return NodeFilter.FILTER_REJECT;
                }
                if (node.offsetParent === null && tag !== "body") {
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
        if (directText.trim().length > 2) {
            textElements.push(node);
        }
    }

    let currentChunk = [];
    let currentWordCount = 0;
    const MAX_WORDS = 500;

    for (const el of textElements) {
        const text = el.textContent.trim();
        const wordCount = text.split(/\s+/).length;

        if (currentWordCount + wordCount > MAX_WORDS && currentChunk.length > 0) {
            const id = `vox-chunk-${chunkCounter++}`;
            const combinedText = currentChunk.map(e => e.textContent.trim()).join("\n\n");
            currentChunk.forEach(e => {
                e.setAttribute(VOX_ID_ATTR, id);
                e.setAttribute(VOX_ATTR, e.textContent);
                e.style.opacity = "0.5";
            });
            chunks.push({ id, text: combinedText, elementCount: currentChunk.length });
            currentChunk = [];
            currentWordCount = 0;
        }

        currentChunk.push(el);
        currentWordCount += wordCount;
    }

    if (currentChunk.length > 0) {
        const id = `vox-chunk-${chunkCounter++}`;
        const combinedText = currentChunk.map(e => e.textContent.trim()).join("\n\n");
        currentChunk.forEach(e => {
            e.setAttribute(VOX_ID_ATTR, id);
            e.setAttribute(VOX_ATTR, e.textContent);
            e.style.opacity = "0.5";
        });
        chunks.push({ id, text: combinedText, elementCount: currentChunk.length });
    }

    return chunks;
}

function applyTranslation(message) {
    const { chunkId, translation, error, progress } = message;
    console.log("[Vox content] applyTranslation:", { chunkId, translation: translation?.substring(0, 100), error, progress });
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
            if (i < translatedParts.length) {
                el.textContent = translatedParts[i];
            }
            el.style.opacity = "1";
        });
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
