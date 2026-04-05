const translateBtn = document.getElementById("translateBtn");
const restoreBtn = document.getElementById("restoreBtn");
const languageSelect = document.getElementById("language");
const progressDiv = document.getElementById("progress");
const progressFill = document.getElementById("progressFill");
const progressText = document.getElementById("progressText");
const errorDiv = document.getElementById("error");

let translating = false;

// Check if page is already translated
browser.tabs.query({ active: true, currentWindow: true }).then(tabs => {
    if (tabs[0]) {
        browser.tabs.sendMessage(tabs[0].id, { action: "getStatus" }).then(r => {
            if (r?.isTranslated) showRestoreState();
        }).catch(() => {});
    }
});

browser.runtime.onMessage.addListener((message) => {
    if (message.action === "progressUpdate") {
        updateProgress(message.current, message.total);
    }
});

translateBtn.addEventListener("click", async () => {
    if (translating) return;
    translating = true;
    errorDiv.style.display = "none";
    translateBtn.disabled = true;
    translateBtn.textContent = "Translating...";
    progressDiv.style.display = "block";
    progressFill.style.width = "0%";

    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    if (tabs[0]) {
        browser.tabs.sendMessage(tabs[0].id, {
            action: "translatePage",
            targetLanguage: languageSelect.value
        });
    }
});

restoreBtn.addEventListener("click", async () => {
    const tabs = await browser.tabs.query({ active: true, currentWindow: true });
    if (tabs[0]) {
        browser.tabs.sendMessage(tabs[0].id, { action: "restorePage" });
    }
    showTranslateState();
});

function updateProgress(current, total) {
    const pct = Math.round((current / total) * 100);
    progressFill.style.width = pct + "%";
    progressText.textContent = `Translating... ${current}/${total}`;
    if (current >= total) {
        translating = false;
        showRestoreState();
    }
}

function showRestoreState() {
    translateBtn.style.display = "none";
    restoreBtn.style.display = "flex";
    progressDiv.style.display = "none";
    translateBtn.disabled = false;
    translateBtn.textContent = "⚡ Translate Page";
}

function showTranslateState() {
    translateBtn.style.display = "flex";
    restoreBtn.style.display = "none";
    translating = false;
}
