console.log("[Vox bg] Background script loaded!");

// ---- Subtitle state cache (avoids rapid sendNativeMessage calls) ----
let _subtitleState = { text: "", timestamp: 0, status: "stopped" };
let _nativePollTimer = null;
let _nativePollBusy = false;

function startNativeSubtitlePoll() {
    if (_nativePollTimer) return;
    console.log("[Vox bg] Starting native subtitle poll");
    pollNativeOnce(); // first poll immediately
    _nativePollTimer = setInterval(pollNativeOnce, 100);
}

function stopNativeSubtitlePoll() {
    if (_nativePollTimer) {
        clearInterval(_nativePollTimer);
        _nativePollTimer = null;
    }
    _nativePollBusy = false;
    _subtitleState = { text: "", timestamp: 0, status: "stopped" };
}

function pollNativeOnce() {
    if (_nativePollBusy) return;
    _nativePollBusy = true;
    browser.runtime.sendNativeMessage("application.id", { action: "getSubtitleUpdate" })
        .then(response => {
            _nativePollBusy = false;
            if (response && typeof response === "object") {
                _subtitleState = response;
                console.log("[Vox bg] Poll got:", (response.text || "").substring(0, 60));
            }
        })
        .catch(e => {
            _nativePollBusy = false;
            console.error("[Vox bg] Poll error:", e.message);
        });
}

// ---- Message handler ----
browser.runtime.onMessage.addListener((request, sender, sendResponse) => {
    console.log("[Vox bg] Message received:", request.action, "from:", sender.tab?.id ?? "popup");

    if (request.action === "startTranslation" || request.action === "enableTranslation") {
        forwardToActiveTab({ action: "enableTranslation", targetLanguage: request.targetLanguage });
        sendResponse({ status: "started" });
        return true;
    }

    if (request.action === "restorePage" || request.action === "disableTranslation") {
        forwardToActiveTab({ action: "disableTranslation" });
        sendResponse({ status: "stopped" });
        return true;
    }

    if (request.action === "getStatus") {
        browser.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            if (tabs[0]) {
                browser.tabs.sendMessage(tabs[0].id, { action: "getStatus" }).then(r => sendResponse(r)).catch(() => sendResponse({ translationActive: false }));
            } else { sendResponse({ translationActive: false }); }
        }).catch(() => sendResponse({ translationActive: false }));
        return true;
    }

    if (request.action === "translateChunks") {
        translateChunks(request.chunks, request.targetLanguage, sender.tab?.id);
        return true;
    }

    if (request.action === "progressUpdate") {
        return;
    }

    if (request.action === "startSubtitles") {
        console.log("[Vox bg] === STARTING SUBTITLES ===");

        // 1. Start native subtitle poll immediately (don't wait for native response)
        startNativeSubtitlePoll();

        // 2. Forward startSubtitlesUI to content script
        browser.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            console.log("[Vox bg] tabs.query result:", tabs.length, "tabs, first:", tabs[0]?.id);
            if (tabs[0]) {
                browser.tabs.sendMessage(tabs[0].id, { action: "startSubtitlesUI" }).catch(e =>
                    console.error("[Vox bg] sendMessage to tab failed:", e.message)
                );
            }
        }).catch(e => console.error("[Vox bg] tabs.query failed:", e));

        // 3. Tell native app to start (fire and forget — response not critical for UI)
        browser.runtime.sendNativeMessage("application.id", { action: "startSubtitles" })
            .then(r => { console.log("[Vox bg] native start response:", JSON.stringify(r)); sendResponse(r); })
            .catch(e => { console.error("[Vox bg] native start error:", e); sendResponse({ error: e.message }); });
        return true;
    }

    if (request.action === "stopSubtitles") {
        stopNativeSubtitlePoll();
        browser.tabs.query({ active: true, currentWindow: true }).then(tabs => {
            if (tabs[0]) {
                browser.tabs.sendMessage(tabs[0].id, { action: "stopSubtitlesUI" }).catch(() => {});
            }
        });
        browser.runtime.sendNativeMessage("application.id", { action: "stopSubtitles" })
            .then(response => sendResponse(response))
            .catch(e => sendResponse({ error: e.message }));
        return true;
    }

    if (request.action === "getSubtitleUpdate") {
        // Return cached state instantly — no native message per poll
        sendResponse(_subtitleState);
        return;
    }
});

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
