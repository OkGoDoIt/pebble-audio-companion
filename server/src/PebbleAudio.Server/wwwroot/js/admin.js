import { createPasskey, signInWithPasskey } from "./passkeys.js";

const csrfToken = document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") ?? "";

/* Passkey forms: sign in, first-run setup, and adding a passkey. */

for (const form of document.querySelectorAll("form[data-passkey]")) {
	form.addEventListener("submit", async (event) => {
		event.preventDefault();

		const status = form.querySelector("[data-status]");
		const button = form.querySelector('button[type="submit"]');
		const setStatus = (message, tone = "info") => {
			if (status) {
				status.textContent = message;
				status.dataset.tone = tone;
			}
		};

		if (button) {
			button.disabled = true;
		}

		try {
			const result = await runCeremony(form, setStatus);
			if (result === null) {
				return;
			}

			const next = typeof result.returnUrl === "string" ? result.returnUrl : "/admin";
			window.location.assign(new URL(next, window.location.origin).toString());
		} catch (error) {
			setStatus(error instanceof Error ? error.message : "Something went wrong. Try again.", "error");
			if (button) {
				button.disabled = false;
			}
		}
	});
}

/**
 * @param {HTMLFormElement} form
 * @param {(message: string) => void} setStatus
 */
function runCeremony(form, setStatus) {
	switch (form.dataset.passkey) {
		case "sign-in":
			return signInWithPasskey({ csrfToken, query: { ReturnUrl: form.dataset.returnUrl ?? "" }, setStatus });
		case "setup": {
			const code = form.querySelector("[data-setup-code]")?.value.trim() ?? "";
			return createPasskey({ csrfToken, headers: { "X-Setup-Code": code }, setStatus });
		}
		case "add": {
			const name = form.querySelector("[data-passkey-name]")?.value.trim() ?? "";
			return createPasskey({ csrfToken, query: { name }, setStatus });
		}
		default:
			throw new Error("This form doesn't know what to do.");
	}
}

/* Copy buttons: data-copy holds a selector for the element whose text to copy. */

for (const button of document.querySelectorAll("button[data-copy]")) {
	const label = button.textContent;
	button.addEventListener("click", async () => {
		const target = document.querySelector(button.dataset.copy);
		if (!target) {
			return;
		}

		try {
			await navigator.clipboard.writeText(target.textContent.trim());
			button.textContent = "Copied";
		} catch {
			window.getSelection()?.selectAllChildren(target);
			button.textContent = "Selected";
		}

		window.setTimeout(() => {
			button.textContent = label;
		}, 2000);
	});
}

/* Cancel inside a disclosure (Unlink's confirmation) closes it. */

for (const button of document.querySelectorAll("button[data-close-details]")) {
	button.addEventListener("click", () => {
		button.closest("details")?.removeAttribute("open");
	});
}

/* Times: the server renders UTC; show them in the viewer's time zone. */

const dateTimeFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" });
const dateFormat = new Intl.DateTimeFormat(undefined, { dateStyle: "medium" });
const relativeFormat = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
const units = [
	["year", 365 * 24 * 3600],
	["month", 30 * 24 * 3600],
	["week", 7 * 24 * 3600],
	["day", 24 * 3600],
	["hour", 3600],
	["minute", 60],
];

function relative(date) {
	const seconds = (date.getTime() - Date.now()) / 1000;
	for (const [unit, size] of units) {
		if (Math.abs(seconds) >= size) {
			return relativeFormat.format(Math.round(seconds / size), unit);
		}
	}

	return "just now";
}

for (const element of document.querySelectorAll("time[data-format]")) {
	const date = new Date(element.getAttribute("datetime") ?? "");
	if (Number.isNaN(date.getTime())) {
		continue;
	}

	element.title = dateTimeFormat.format(date);
	switch (element.dataset.format) {
		case "date":
			element.textContent = dateFormat.format(date);
			break;
		case "relative":
			element.textContent = relative(date);
			break;
		default:
			element.textContent = dateTimeFormat.format(date);
			break;
	}
}
