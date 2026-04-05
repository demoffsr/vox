// Background service worker — routes messages between content.js and native handler

browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "translateChunks") {
        translateChunks(request.chunks, request.targetLanguage, sender.tab?.id);
        return true;
    }
});

async function translateChunks(chunks, targetLanguage, tabId) {
    const total = chunks.length;

    for (let i = 0; i < total; i++) {
        try {
            const response = await browser.runtime.sendNativeMessage(
                "application.id",
                {
                    action: "translate",
                    text: chunks[i].text,
                    targetLanguage: targetLanguage || "Auto"
                }
            );

            if (tabId) {
                browser.tabs.sendMessage(tabId, {
                    action: "translationResult",
                    chunkId: chunks[i].id,
                    translation: response.translation,
                    error: response.error,
                    progress: { current: i + 1, total: total }
                });
            }
        } catch (error) {
            if (tabId) {
                browser.tabs.sendMessage(tabId, {
                    action: "translationResult",
                    chunkId: chunks[i].id,
                    error: error.message || "Translation failed",
                    progress: { current: i + 1, total: total }
                });
            }
        }
    }
}
