/**
 * Passkey (WebAuthn) ceremonies against ASP.NET Core Identity's passkey handlers. Each ceremony is two POSTs
 * to Razor Page handlers on the current page: one for the options, one with the browser's credential.
 * Ported from Situ's passkey-auth.js, which is known to work with Identity's JSON parser.
 */

const TOKEN_REFRESHED_KEY = "pebbleaudio.passkeyTokenRefreshed";

/**
 * Creates a passkey and returns the server's final JSON ({ ok, returnUrl }).
 *
 * @param {{ csrfToken: string, headers?: Record<string, string>, query?: Record<string, string>, setStatus?: (message: string) => void }} options
 * @returns {Promise<Record<string, unknown> | null>} null when the page reloads to pick up a fresh token.
 */
export async function createPasskey({ csrfToken, headers = {}, query = {}, setStatus }) {
	requireSupport("parseCreationOptionsFromJSON");
	setStatus?.("Getting ready…");

	const optionsJson = await postForOptions("PasskeyCreationOptions", csrfToken, headers, query);
	if (optionsJson === null) {
		return null;
	}

	setStatus?.("Confirm with Face ID, Touch ID, or your device's screen lock…");
	const publicKey = PublicKeyCredential.parseCreationOptionsFromJSON(optionsJson);

	let credential;
	try {
		credential = await navigator.credentials.create({ publicKey });
	} catch (error) {
		throwFriendly(error, "The passkey wasn't created. Try again when you're ready.");
	}

	if (!credential) {
		throw new Error("The passkey wasn't created. Try again when you're ready.");
	}

	setStatus?.("Saving…");
	return postCredential("PasskeyAttestation", credential, csrfToken, headers, query);
}

/**
 * Signs in with a discoverable passkey and returns the server's final JSON ({ ok, returnUrl }).
 *
 * @param {{ csrfToken: string, query?: Record<string, string>, setStatus?: (message: string) => void }} options
 * @returns {Promise<Record<string, unknown> | null>} null when the page reloads to pick up a fresh token.
 */
export async function signInWithPasskey({ csrfToken, query = {}, setStatus }) {
	requireSupport("parseRequestOptionsFromJSON");
	setStatus?.("Getting ready…");

	const optionsJson = await postForOptions("PasskeyRequestOptions", csrfToken, {}, query);
	if (optionsJson === null) {
		return null;
	}

	setStatus?.("Confirm with Face ID, Touch ID, or your device's screen lock…");
	const publicKey = PublicKeyCredential.parseRequestOptionsFromJSON(optionsJson);

	let assertion;
	try {
		assertion = await navigator.credentials.get({ publicKey });
	} catch (error) {
		throwFriendly(error, "You weren't signed in. Try again when you're ready.");
	}

	if (!assertion) {
		throw new Error("You weren't signed in. Try again when you're ready.");
	}

	setStatus?.("Signing in…");
	return postCredential("PasskeySignIn", assertion, csrfToken, {}, query);
}

/**
 * @param {string} method
 */
function requireSupport(method) {
	if (!window.PublicKeyCredential) {
		throw new Error("This browser doesn't support passkeys.");
	}

	if (typeof PublicKeyCredential[method] !== "function") {
		throw new Error("This browser can't use passkeys here. Try a current Safari, Chrome, Edge, or Firefox.");
	}
}

/**
 * @param {string} handler
 * @param {string} csrfToken
 * @param {Record<string, string>} headers
 * @param {Record<string, string>} query
 * @returns {Promise<unknown | null>}
 */
async function postForOptions(handler, csrfToken, headers, query) {
	const response = await fetch(handlerUrl(handler, query), {
		method: "POST",
		credentials: "same-origin",
		headers: { RequestVerificationToken: csrfToken, ...headers },
	});

	// A stale antiforgery cookie fails the first POST with a bare 400; reload once for a fresh one.
	if (response.status === 400 && sessionStorage.getItem(TOKEN_REFRESHED_KEY) !== "1") {
		sessionStorage.setItem(TOKEN_REFRESHED_KEY, "1");
		window.location.reload();
		return null;
	}

	if (!response.ok) {
		await throwServerError(response);
	}

	sessionStorage.removeItem(TOKEN_REFRESHED_KEY);
	return response.json();
}

/**
 * @param {string} handler
 * @param {Credential} credential
 * @param {string} csrfToken
 * @param {Record<string, string>} headers
 * @param {Record<string, string>} query
 */
async function postCredential(handler, credential, csrfToken, headers, query) {
	const response = await fetch(handlerUrl(handler, query), {
		method: "POST",
		credentials: "same-origin",
		headers: { RequestVerificationToken: csrfToken, "Content-Type": "application/json", ...headers },
		body: JSON.stringify(credentialToJson(credential)),
	});

	if (!response.ok) {
		await throwServerError(response);
	}

	const text = await response.text();
	try {
		const result = JSON.parse(text);
		return result && typeof result === "object" ? result : {};
	} catch {
		return {};
	}
}

/**
 * @param {string} handler
 * @param {Record<string, string>} query
 */
function handlerUrl(handler, query) {
	const url = new URL(window.location.pathname, window.location.origin);
	url.searchParams.set("handler", handler);
	for (const [key, value] of Object.entries(query)) {
		if (value) {
			url.searchParams.set(key, value);
		}
	}

	return url.toString();
}

/**
 * @param {Response} response
 * @returns {Promise<never>}
 */
async function throwServerError(response) {
	let message = "Something went wrong. Try again.";
	try {
		const data = await response.json();
		if (data && typeof data.error === "string" && data.error.length > 0) {
			message = data.error;
		}
	} catch {
		// Not JSON; keep the general message.
	}

	throw new Error(message);
}

/**
 * Browsers report a dismissed, cancelled, or timed-out prompt with these names.
 *
 * @param {unknown} error
 * @param {string} message
 * @returns {never}
 */
function throwFriendly(error, message) {
	const name = error && typeof error === "object" ? /** @type {{ name?: unknown }} */ (error).name : undefined;
	if (typeof name === "string" && ["AbortError", "NotAllowedError", "TimeoutError"].includes(name)) {
		throw new Error(message);
	}

	if (name === "InvalidStateError") {
		throw new Error("This device already has a passkey for this account.");
	}

	throw error;
}

/**
 * Serializes the credential by hand: some browsers and password managers implement toJSON() in ways
 * Identity's parser rejects.
 *
 * @param {Credential} credential
 */
function credentialToJson(credential) {
	const publicKeyCredential = /** @type {PublicKeyCredential} */ (credential);
	const response = /** @type {any} */ (publicKeyCredential.response);

	return {
		authenticatorAttachment: publicKeyCredential.authenticatorAttachment,
		clientExtensionResults: publicKeyCredential.getClientExtensionResults(),
		id: publicKeyCredential.id,
		rawId: toBase64Url(publicKeyCredential.rawId),
		response: {
			attestationObject: toBase64Url(response.attestationObject),
			authenticatorData: toBase64Url(response.authenticatorData ?? response.getAuthenticatorData?.()),
			clientDataJSON: toBase64Url(response.clientDataJSON),
			publicKey: toBase64Url(response.getPublicKey?.() ?? undefined),
			publicKeyAlgorithm: response.getPublicKeyAlgorithm?.(),
			signature: toBase64Url(response.signature),
			transports: response.getTransports?.(),
			userHandle: toBase64Url(response.userHandle),
		},
		type: publicKeyCredential.type,
	};
}

/**
 * @param {unknown} value
 * @returns {string | undefined}
 */
function toBase64Url(value) {
	if (!value) {
		return undefined;
	}

	if (typeof value === "string") {
		return value;
	}

	const bytes = value instanceof ArrayBuffer
		? new Uint8Array(value)
		: ArrayBuffer.isView(value)
			? new Uint8Array(value.buffer, value.byteOffset, value.byteLength)
			: null;
	if (!bytes) {
		throw new Error("The passkey returned a value this page can't read.");
	}

	let binary = "";
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}

	return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
