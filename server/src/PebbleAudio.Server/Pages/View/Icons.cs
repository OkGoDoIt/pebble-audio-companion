using Microsoft.AspNetCore.Html;

namespace PebbleAudio.Server.Pages.View;

/// <summary>The viewer's few inline icons, colored by <c>currentColor</c>.</summary>
public static class Icons
{
	public static IHtmlContent Back { get; } = new HtmlString(
		"<svg class=\"chev\" width=\"10\" height=\"17\" viewBox=\"0 0 10 17\" aria-hidden=\"true\"><path d=\"M8.5 1.5 1.5 8.5l7 7\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2.2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>");

	public static IHtmlContent Forward { get; } = new HtmlString(
		"<svg class=\"chev\" width=\"9\" height=\"15\" viewBox=\"0 0 9 15\" aria-hidden=\"true\"><path d=\"M1.5 1.5l6 6-6 6\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>");

	public static IHtmlContent Person { get; } = new HtmlString(
		"<svg width=\"12\" height=\"12\" viewBox=\"0 0 12 12\" aria-hidden=\"true\"><circle cx=\"6\" cy=\"3.6\" r=\"2.4\" fill=\"currentColor\"/><path d=\"M1.5 11c.4-2.6 2.2-4 4.5-4s4.1 1.4 4.5 4z\" fill=\"currentColor\"/></svg>");

	public static IHtmlContent Circle { get; } = new HtmlString(
		"<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" aria-hidden=\"true\"><circle cx=\"7\" cy=\"7\" r=\"5.6\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.4\"/></svg>");

	public static IHtmlContent Done { get; } = new HtmlString(
		"<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" aria-hidden=\"true\"><circle cx=\"7\" cy=\"7\" r=\"6.3\" fill=\"currentColor\"/><path d=\"M4.2 7.2l1.9 1.9 3.8-4\" fill=\"none\" stroke=\"var(--surface)\" stroke-width=\"1.5\" stroke-linecap=\"round\" stroke-linejoin=\"round\"/></svg>");

	public static IHtmlContent Play { get; } = new HtmlString(
		"<svg width=\"9\" height=\"9\" viewBox=\"0 0 10 10\" aria-hidden=\"true\"><path d=\"M2 1.2v7.6a.6.6 0 0 0 .9.5l6-3.8a.6.6 0 0 0 0-1L2.9.7a.6.6 0 0 0-.9.5z\" fill=\"currentColor\"/></svg>");
}
