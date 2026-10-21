using Microsoft.AspNetCore.Html;

namespace PebbleAudio.Server.Pages;

/// <summary>
/// The server pages' glyphs, drawn as the round-3 mockups draw them (docs/redesign/assistant-access-mockups/round3/
/// chrome.js): a 24-unit box, a 1.9 stroke in <c>currentColor</c>, round caps.
/// </summary>
public static class SiteIcons
{
	private static HtmlString Glyph(string paths) => new(
		$"<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.9\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\">{paths}</svg>");

	public static IHtmlContent Conversations { get; } = Glyph("<path d=\"M7 3.5h7l4 4V20a.5.5 0 0 1-.5.5h-10A.5.5 0 0 1 7 20z\"/><path d=\"M14 3.5V8h4M10 12h5M10 16h5\"/>");

	public static IHtmlContent Key { get; } = Glyph("<circle cx=\"8\" cy=\"15\" r=\"3.5\"/><path d=\"M10.5 12.5 19 4M16 7l2.5 2.5M14 9l2 2\"/>");

	public static IHtmlContent Plus { get; } = Glyph("<path d=\"M12 5v14M5 12h14\"/>");

	public static IHtmlContent Camera { get; } = Glyph("<path d=\"M4 8.5A1.5 1.5 0 0 1 5.5 7h2.2l1.5-2h5.6l1.5 2h2.2A1.5 1.5 0 0 1 20 8.5v9a1.5 1.5 0 0 1-1.5 1.5h-13A1.5 1.5 0 0 1 4 17.5z\"/><circle cx=\"12\" cy=\"13\" r=\"3.4\"/>");

	public static IHtmlContent Gear { get; } = Glyph("<circle cx=\"12\" cy=\"12\" r=\"3.2\"/><path d=\"M12 2.8v2.6M12 18.6v2.6M21.2 12h-2.6M5.4 12H2.8M18.5 5.5l-1.8 1.8M7.3 16.7l-1.8 1.8M18.5 18.5l-1.8-1.8M7.3 7.3L5.5 5.5\"/>");

	public static IHtmlContent Dots { get; } = Glyph("<circle cx=\"6\" cy=\"12\" r=\"1.3\" fill=\"currentColor\"/><circle cx=\"12\" cy=\"12\" r=\"1.3\" fill=\"currentColor\"/><circle cx=\"18\" cy=\"12\" r=\"1.3\" fill=\"currentColor\"/>");

	public static IHtmlContent Copy { get; } = Glyph("<rect x=\"8.5\" y=\"8.5\" width=\"11.5\" height=\"11.5\" rx=\"2.2\"/><path d=\"M15.5 8.5V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v7.5a2 2 0 0 0 2 2h2.5\"/>");

	public static IHtmlContent External { get; } = Glyph("<path d=\"M14 4h6v6M20 4l-9 9\"/><path d=\"M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10\"/>");

	public static IHtmlContent Phone { get; } = Glyph("<rect x=\"7\" y=\"2.8\" width=\"10\" height=\"18.4\" rx=\"2.6\"/><path d=\"M10.8 18h2.4\"/>");

	public static IHtmlContent Watch { get; } = Glyph("<rect x=\"6.5\" y=\"6\" width=\"11\" height=\"12\" rx=\"3\"/><path d=\"M9 6l.6-3h4.8l.6 3M9 18l.6 3h4.8l.6-3\"/>");

	public static IHtmlContent Server { get; } = Glyph("<rect x=\"3.5\" y=\"4\" width=\"17\" height=\"6.5\" rx=\"1.8\"/><rect x=\"3.5\" y=\"13.5\" width=\"17\" height=\"6.5\" rx=\"1.8\"/><path d=\"M7 7.25h.01M7 16.75h.01\" stroke-width=\"2.8\"/>");

	public static IHtmlContent Lock { get; } = Glyph("<rect x=\"5\" y=\"10.5\" width=\"14\" height=\"10\" rx=\"2.2\"/><path d=\"M8 10.5V8a4 4 0 0 1 8 0v2.5\"/>");

	public static IHtmlContent Bell { get; } = Glyph("<path d=\"M6 16.5V11a6 6 0 0 1 12 0v5.5l1.5 2h-15z\"/><path d=\"M10 20.5a2 2 0 0 0 4 0\"/>");

	/// <summary>The white check inside a green badge.</summary>
	public static IHtmlContent Check { get; } = new HtmlString(
		"<svg viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.8\" stroke-linecap=\"round\" stroke-linejoin=\"round\" aria-hidden=\"true\"><path d=\"M5 12.5l4.5 4.5L19 7.5\"/></svg>");

	/// <summary>A row's disclosure chevron, 8 by 14.</summary>
	public static IHtmlContent Chevron { get; } = new HtmlString(
		"<svg class=\"chev\" viewBox=\"0 0 8 14\" fill=\"none\" aria-hidden=\"true\"><path d=\"M1 1l6 6-6 6\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>");
}
