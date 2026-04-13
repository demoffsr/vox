console.log("[Vox popup] Popup loaded");

const toggleSwitch = document.getElementById("toggleSwitch");
const toggleLabel = document.getElementById("toggleLabel");
const languageSelect = document.getElementById("language");
const languageLabel = document.getElementById("languageLabel");
const languageCapsule = document.getElementById("languageCapsule");
const progressDiv = document.getElementById("progress");
const progressFill = document.getElementById("progressFill");
const progressText = document.getElementById("progressText");
const errorDiv = document.getElementById("error");

// Sync capsule label with hidden select
languageSelect.addEventListener("change", () => {
    languageLabel.textContent = languageSelect.options[languageSelect.selectedIndex].text;
});
languageCapsule.addEventListener("click", () => {
    languageSelect.showPicker?.();
});

// Check current state on popup open
browser.runtime.sendMessage({ action: "getStatus" }).then(status => {
    if (status?.translationActive) {
        toggleSwitch.checked = true;
        toggleLabel.textContent = "Translation on";
        if (status.language) {
            for (let i = 0; i < languageSelect.options.length; i++) {
                if (languageSelect.options[i].value === status.language) {
                    languageSelect.selectedIndex = i;
                    languageLabel.textContent = languageSelect.options[i].text;
                    break;
                }
            }
        }
    }
}).catch(() => {});

// Resolve "Auto" to the user's primary target language from app settings
async function resolveLanguage(value) {
    if (value !== "Auto") return value;
    try {
        const settings = await browser.runtime.sendMessage({ action: "getSettings" });
        return settings?.primaryLanguage || "Russian";
    } catch {
        return "Russian";
    }
}

// Toggle handler
toggleSwitch.addEventListener("change", async () => {
    errorDiv.style.display = "none";

    if (toggleSwitch.checked) {
        toggleLabel.textContent = "Translation on";
        progressDiv.style.display = "block";
        progressFill.style.width = "0%";
        progressText.textContent = "Translating...";

        try {
            const language = await resolveLanguage(languageSelect.value);
            await browser.runtime.sendMessage({
                action: "enableTranslation",
                targetLanguage: language
            });
        } catch (e) {
            showError("Failed to start: " + e.message);
            toggleSwitch.checked = false;
            toggleLabel.textContent = "Translation off";
        }
    } else {
        toggleLabel.textContent = "Translation off";
        progressDiv.style.display = "none";

        try {
            await browser.runtime.sendMessage({ action: "disableTranslation" });
        } catch (e) {
            console.error("[Vox popup] Disable error:", e);
        }
    }
});

// Listen for progress
browser.runtime.onMessage.addListener((message) => {
    if (message.action === "progressUpdate") {
        updateProgress(message.current, message.total);
    }
    if (message.action === "error") {
        showError(message.text);
    }
});

function updateProgress(current, total) {
    progressDiv.style.display = "block";
    const pct = Math.round((current / total) * 100);
    progressFill.style.width = pct + "%";
    progressText.textContent = `${current} / ${total}`;
    if (current >= total) {
        setTimeout(() => { progressDiv.style.display = "none"; }, 1500);
    }
}

function showError(msg) {
    errorDiv.textContent = msg;
    errorDiv.style.display = "block";
    progressDiv.style.display = "none";
}
