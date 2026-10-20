using System.ComponentModel.DataAnnotations;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using Microsoft.Extensions.Options;
using PebbleAudio.Server.Auth;
using PebbleAudio.Server.Data;

namespace PebbleAudio.Server.Pages.Admin;

public sealed class TokensModel(ApiTokenService tokens, IOptions<PebbleAudioOptions> options) : PageModel
{
	public IReadOnlyList<ApiToken> Tokens { get; private set; } = [];

	public string McpUrl => $"{options.Value.PublicOrigin}/mcp";

	/// <summary>The token just created, shown once.</summary>
	public CreatedToken? Created { get; private set; }

	[BindProperty]
	public CreateTokenInput Input { get; set; } = new();

	public async Task OnGetAsync(CancellationToken cancellationToken) => await LoadAsync(cancellationToken);

	public async Task<IActionResult> OnPostCreateAsync(CancellationToken cancellationToken)
	{
		var userId = CurrentUserId();
		if (!ModelState.IsValid)
		{
			await LoadAsync(cancellationToken);
			return Page();
		}

		var (_, secret) = await tokens.CreateAsync(userId, Input.Name!, Input.Access, cancellationToken);
		Created = new CreatedToken(secret);
		ModelState.Clear();
		Input = new CreateTokenInput();
		await LoadAsync(cancellationToken);
		return Page();
	}

	public async Task<IActionResult> OnPostRevokeAsync(Guid id, CancellationToken cancellationToken)
	{
		await tokens.RevokeAsync(CurrentUserId(), id, cancellationToken);
		return RedirectToPage();
	}

	private async Task LoadAsync(CancellationToken cancellationToken) =>
		Tokens = await tokens.ListAsync(CurrentUserId(), cancellationToken);

	private Guid CurrentUserId() =>
		User.UserId() ?? throw new InvalidOperationException("The admin page requires a signed-in user.");

	public sealed class CreateTokenInput
	{
		[Required(ErrorMessage = "Give the token a name.")]
		[StringLength(80, ErrorMessage = "Keep the name under 80 characters.")]
		public string? Name { get; set; }

		public TokenAccess Access { get; set; } = TokenAccess.Read;
	}

	public sealed record CreatedToken(string Secret);
}
