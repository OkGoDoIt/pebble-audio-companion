import { createPasskey, signInWithPasskey } from "./passkeys.js";

// The server's own pages: passkey forms, copy buttons, confirmations, and small dialogs.

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

			const next = typeof result.returnUrl === "string" ? result.returnUrl : "/";
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

/* Copy buttons: data-copy names the element whose text to copy, data-copy-value the text itself. The button's
   words say Copied for a moment; with no clipboard, the text is selected for the person to copy. */

for (const button of document.querySelectorAll("button[data-copy], button[data-copy-value]")) {
	const label = button.querySelector("span") ?? button;
	const words = label.textContent;
	button.addEventListener("click", async () => {
		const target = button.dataset.copy ? document.querySelector(button.dataset.copy) : null;
		const text = button.dataset.copyValue ?? target?.textContent.trim() ?? "";
		try {
			await navigator.clipboard.writeText(text);
			label.textContent = "Copied";
		} catch {
			if (target) {
				window.getSelection()?.selectAllChildren(target);
				label.textContent = "Selected";
			}
		}

		window.setTimeout(() => {
			label.textContent = words;
		}, 2000);
	});
}

/* Confirmations: a form with data-confirm asks in its own dialog before it is sent. The dialog's own submit button
   (data-confirmed) sends it; without scripts the form is sent straight away. */

for (const form of document.querySelectorAll("form[data-confirm]")) {
	const dialog = form.querySelector("dialog");
	if (!dialog) {
		continue;
	}

	form.addEventListener("submit", (event) => {
		if (event.submitter && "confirmed" in event.submitter.dataset) {
			return;
		}

		event.preventDefault();
		dialog.showModal();
	});
	wireDialog(dialog);
}

/* Small dialogs opened by a button (renaming a phone): data-dialog names the dialog. */

for (const button of document.querySelectorAll("button[data-dialog]")) {
	const dialog = document.querySelector(button.dataset.dialog);
	if (!(dialog instanceof HTMLDialogElement)) {
		continue;
	}

	button.addEventListener("click", () => {
		dialog.showModal();
		dialog.querySelector("input")?.select();
	});
	wireDialog(dialog);
}

/** Cancel closes it, and so does a tap on the dimmed page around it. */
function wireDialog(dialog) {
	if (dialog.dataset.wired) {
		return;
	}

	dialog.dataset.wired = "true";
	for (const cancel of dialog.querySelectorAll("[data-cancel]")) {
		cancel.addEventListener("click", () => dialog.close());
	}

	dialog.addEventListener("click", (event) => {
		if (event.target === dialog) {
			const box = dialog.getBoundingClientRect();
			const inside = event.clientX >= box.left && event.clientX <= box.right && event.clientY >= box.top && event.clientY <= box.bottom;
			if (!inside) {
				dialog.close();
			}
		}
	});
}
