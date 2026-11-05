using System.Collections.Concurrent;
using System.Net;
using AudibleApi;
using AudibleUtilities;
using LibationFileManager;

namespace LibationHost;

public record LoginCookieDto(string Name, string Value, string Domain, string Path, bool Secure);

public record LoginSessionDto(
	string Id,
	string AccountId,
	string? Locale,
	string LoginUrl,
	string UserAgent,
	IReadOnlyList<LoginCookieDto> Cookies);

/// <summary>
/// The host's answer to the GUIs' login dialogs. AudibleApi asks for an <see cref="ILoginChoiceEager"/>
/// when stored tokens cannot be used; this one hands the login URL to the front end over SSE and waits
/// for it to post back the URL the browser lands on after sign-in (the /ap/maplanding redirect).
/// </summary>
public sealed class LoginBroker
{
	private readonly EventHub _hub;
	private readonly ConcurrentDictionary<string, (LoginSessionDto session, TaskCompletionSource<string?> tcs)> _pending = new();

	public LoginBroker(EventHub hub) => _hub = hub;

	public IEnumerable<LoginSessionDto> Pending => _pending.Values.Select(p => p.session);

	public ILoginChoiceEager ChoiceFor(Account account) => new HostLoginChoice(this, account);

	public bool Complete(string id, string responseUrl)
	{
		if (!Uri.TryCreate(responseUrl, UriKind.Absolute, out _)) return false;
		return _pending.TryRemove(id, out var p) && p.tcs.TrySetResult(responseUrl);
	}

	public bool Cancel(string id) => _pending.TryRemove(id, out var p) && p.tcs.TrySetResult(null);

	private async Task<string?> StartAsync(Account account, ChoiceIn choiceIn)
	{
		var cookies = new List<LoginCookieDto>();
		foreach (Cookie c in choiceIn.SignInCookies ?? new CookieCollection())
			if (!string.IsNullOrEmpty(c.Value))
				cookies.Add(new(c.Name, c.Value, c.Domain, string.IsNullOrEmpty(c.Path) ? "/" : c.Path, c.Secure));

		var session = new LoginSessionDto(
			Guid.NewGuid().ToString("N"),
			account.AccountId,
			account.Locale?.Name,
			choiceIn.LoginUrl,
			Configuration.Instance.GetDeviceRegistrationProfile().UserAgent,
			cookies);

		var tcs = new TaskCompletionSource<string?>(TaskCreationOptions.RunContinuationsAsynchronously);
		_pending[session.Id] = (session, tcs);
		Serilog.Log.Logger.Information("Interactive login requested for {Account}; waiting on front end", account.MaskedLogEntry);
		_hub.Publish("login", session);

		// Give the user as long as they need, but never leak a session forever.
		using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(30));
		using var _ = cts.Token.Register(() => Cancel(session.Id));
		var result = await tcs.Task;
		_hub.Publish("login", new { id = session.Id, closed = true, completed = result is not null });
		return result;
	}

	private sealed class HostLoginChoice : ILoginChoiceEager
	{
		private readonly LoginBroker _broker;
		private readonly Account _account;
		public HostLoginChoice(LoginBroker broker, Account account) { _broker = broker; _account = account; }
		public Task<string?> StartAsync(ChoiceIn choiceIn) => _broker.StartAsync(_account, choiceIn);
	}
}
