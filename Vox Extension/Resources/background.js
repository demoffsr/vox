console.log("[Vox bg] Background script loaded!");

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    console.log("[Vox bg] Message received:", request.action, "from:", sender.tab?.id ?? "popup");

    if (request.action === "startTranslation") {
        // Popup asked to start — forward to active tab's content script
        handleStartTranslation(request.targetLanguage);
        sendResponse({ status: "started" });
        return true;
    }

    if (request.action === "restorePage") {
        forwardToActiveTab({ action: "restorePage" });
        return;
    }

    if (request.action === "translateChunks") {
        // Content script sent chunks to translate
        translateChunks(request.chunks, request.targetLanguage, sender.tab?.id);
        return true;
    }

    if (request.action === "progressUpdate") {
        // Forward progress to popup (it might be listening)
        return;
    }

    if (request.action === "startSubtitles") {
        browser.runtime.sendNativeMessage("application.id", { action: "startSubtitles" })
            .then(response => sendResponse(response))
            .catch(e => sendResponse({ error: e.message }));
        return true;
    }

    if (request.action === "stopSubtitles") {
        browser.runtime.sendNativeMessage("application.id", { action: "stopSubtitles" })
            .then(response => sendResponse(response))
            .catch(e => sendResponse({ error: e.message }));
        return true;
    }

    if (request.action === "getSubtitleUpdate") {
        browser.runtime.sendNativeMessage("application.id", { action: "getSubtitleUpdate" })
            .then(response => sendResponse(response))
            .catch(e => sendResponse({ error: e.message }));
        return true;
    }
});

async function handleStartTranslation(targetLanguage) {
    console.log("[Vox bg] Starting translation, language:", targetLanguage);
    try {
        const tabs = await browser.tabs.query({ active: true, currentWindow: true });
        console.log("[Vox bg] Active tab:", tabs[0]?.id, tabs[0]?.url);
        if (tabs[0]) {
            await browser.tabs.sendMessage(tabs[0].id, {
                action: "translatePage",
                targetLanguage: targetLanguage
            });
            console.log("[Vox bg] Sent translatePage to tab");
        }
    } catch (e) {
        console.error("[Vox bg] Error sending to tab:", e);
    }
}

async function forwardToActiveTab(message) {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    if (tabs[0]) {
        browser.tabs.sendMessage(tabs[0].id, message);
    }
}

async function translateChunks(chunks, targetLanguage, tabId) {
    const total = chunks.length;
    const CONCURRENCY = 5;
    let completed = 0;
    console.log("[Vox bg] Translating", total, "chunks for tab", tabId, "(concurrency:", CONCURRENCY + ")");

    async function translateOne(chunk) {
        try {
            const response = await browser.runtime.sendNativeMessage(
                "application.id",
                {
                    action: "translate",
                    text: chunk.text,
                    targetLanguage: targetLanguage || "Auto"
                }
            );
            completed++;
            console.log("[Vox bg] Chunk done", completed, "/", total);
            if (tabId) {
                browser.tabs.sendMessage(tabId, {
                    action: "translationResult",
                    chunkId: chunk.id,
                    translation: response.translation,
                    error: response.error,
                    progress: { current: completed, total }
                });
            }
        } catch (error) {
            completed++;
            console.error("[Vox bg] Native message error:", error);
            if (tabId) {
                browser.tabs.sendMessage(tabId, {
                    action: "translationResult",
                    chunkId: chunk.id,
                    error: error.message || "Translation failed",
                    progress: { current: completed, total }
                });
            }
        }
    }

    // Run with concurrency limit
    const executing = new Set();
    for (const chunk of chunks) {
        const p = translateOne(chunk);
        executing.add(p);
        p.then(() => executing.delete(p));
        if (executing.size >= CONCURRENCY) {
            await Promise.race(executing);
        }
    }
    await Promise.all(executing);
}
