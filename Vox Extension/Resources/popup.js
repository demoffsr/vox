console.log("[Vox popup] Popup loaded");

const translateBtn = document.getElementById("translateBtn");
const restoreBtn = document.getElementById("restoreBtn");
const languageSelect = document.getElementById("language");
const progressDiv = document.getElementById("progress");
const progressFill = document.getElementById("progressFill");
const progressText = document.getElementById("progressText");
const errorDiv = document.getElementById("error");

let translating = false;

translateBtn.addEventListener("click", async () => {
    console.log("[Vox popup] Translate clicked");
    if (translating) return;
    translating = true;
    errorDiv.style.display = "none";
    translateBtn.disabled = true;
    translateBtn.textContent = "Translating...";
    progressDiv.style.display = "block";
    progressFill.style.width = "0%";

    try {
        // Send directly to background via runtime (not tabs)
        const response = await browser.runtime.sendMessage({
            action: "startTranslation",
            targetLanguage: languageSelect.value
        });
        console.log("[Vox popup] Background responded:", response);
    } catch (e) {
        console.error("[Vox popup] Error:", e);
        showError("Failed to start translation: " + e.message);
    }
});

restoreBtn.addEventListener("click", async () => {
    try {
        await browser.runtime.sendMessage({ action: "restorePage" });
    } catch (e) {
        console.error("[Vox popup] Restore error:", e);
    }
    showTranslateState();
});

// Listen for progress
browser.runtime.onMessage.addListener((message) => {
    console.log("[Vox popup] Got message:", message.action);
    if (message.action === "progressUpdate") {
        updateProgress(message.current, message.total);
    }
    if (message.action === "error") {
        showError(message.text);
    }
});

function updateProgress(current, total) {
    const pct = Math.round((current / total) * 100);
    progressFill.style.width = pct + "%";
    progressText.textContent = `${current} / ${total}`;
    if (current >= total) {
        translating = false;
        showRestoreState();
    }
}

function showError(msg) {
    errorDiv.textContent = msg;
    errorDiv.style.display = "block";
    translating = false;
    translateBtn.disabled = false;
    translateBtn.textContent = "⚡ Translate Page";
    progressDiv.style.display = "none";
}

function showRestoreState() {
    translateBtn.style.display = "none";
    restoreBtn.style.display = "flex";
    progressDiv.style.display = "none";
}

function showTranslateState() {
    translateBtn.style.display = "flex";
    restoreBtn.style.display = "none";
    translateBtn.disabled = false;
    translateBtn.textContent = "⚡ Translate Page";
    translating = false;
}
