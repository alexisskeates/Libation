using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using ApplicationServices;
using AppScaffolding;
using AudibleUtilities;
using DataLayer;
using LibationFileManager;
using LibationHost;
using LibationUiBase;
using LibationUiBase.Forms;
using Microsoft.AspNetCore.Http.Json;

// ---- arguments -------------------------------------------------------------
int port = 0;
string? token = null;
for (var i = 0; i < args.Length; i++)
{
	if (args[i] == "--port" && i + 1 < args.Length) port = int.Parse(args[++i]);
	else if (args[i] == "--token" && i + 1 < args.Length) token = args[++i];
}

// ---- Libation bootstrap (mirrors LibationCli.Setup / LibationAvalonia.App) -----
var config = LibationScaffolding.RunPreConfigMigrations();
if (!Directory.Exists(config.LibationFiles.Location) || !config.LibationFiles.SettingsAreValid)
{
	Console.Error.WriteLine($"LibationFiles not set up at {config.LibationFiles.Location}. Run Libation once, or set {LibationFiles.LIBATION_FILES_DIR}.");
	return 2;
}
LibationScaffolding.RunPostConfigMigrations(config);
LibationScaffolding.RunPostMigrationScaffolding(Variety.Chardonnay, config);

using var instanceLock = SingleInstance.TryAcquire(config.LibationFiles.Location);
if (!instanceLock.IsFirstInstance)
	Serilog.Log.Logger.Warning("Another Libation instance owns this LibationFiles folder; concurrent writes may conflict.");

// Default cover art, so PictureStorage has something to hand back before a download finishes.
static byte[] Embedded(string name)
{
	using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)!;
	using var ms = new MemoryStream(); s.CopyTo(ms); return ms.ToArray();
}
PictureStorage.SetDefaultImage(PictureSize._80x80, Embedded("default80.jpg"));
PictureStorage.SetDefaultImage(PictureSize._300x300, Embedded("default300.jpg"));
PictureStorage.SetDefaultImage(PictureSize._500x500, Embedded("default500.jpg"));
PictureStorage.SetDefaultImage(PictureSize.Native, Embedded("default500.jpg"));
BaseUtil.SetLoadImageDelegate((bytes, _) => bytes);

var json = new JsonSerializerOptions(JsonSerializerDefaults.Web) { Converters = { new JsonStringEnumConverter() } };
var hub = new EventHub(json);
// View models marshal notifications through the captured context; give them an ordered one.
SynchronizationContext.SetSynchronizationContext(new HostSyncContext());
var queue = new HostQueue(hub);

// Dialogs the core wants to show become "alert" events; the front end renders them. Modal
// questions are answered with their first button for now.
MessageBoxBase.ShowAsyncImpl = (_, message, caption, buttons, icon, _, _) =>
{
	Serilog.Log.Logger.Information("Alert forwarded to front end: {Caption}: {Message}", caption, message);
	hub.Publish("alert", new AlertDto(caption, message, buttons.ToString(), icon.ToString()));
	var answer = buttons switch
	{
		MessageBoxButtons.YesNo or MessageBoxButtons.YesNoCancel => DialogResult.Yes,
		MessageBoxButtons.RetryCancel => DialogResult.Cancel,
		MessageBoxButtons.AbortRetryIgnore => DialogResult.Ignore,
		_ => DialogResult.OK,
	};
	return Task.FromResult(answer);
};

var scan = new ScanStateDto(false, null, null, null);
LibraryCommands.ScanBegin += (_, count) => { scan = new(true, null, null, null); hub.Publish("scan", scan); };
LibraryCommands.ScanEnd += (_, count) => { scan = scan with { Scanning = false }; hub.Publish("scan", scan); };
LibraryCommands.LibrarySizeChanged += (_, _) => hub.Publish("library", new { reason = "size" });
LibraryCommands.BookUserDefinedItemCommitted += (_, books) => hub.Publish("library", new { reason = "userItems", asins = books.Select(b => b.Book.AudibleProductId).ToArray() });
SearchEngineCommands.SearchEngineUpdated += (_, _) => hub.Publish("library", new { reason = "search" });

// ---- web host ----------------------------------------------------------------
var builder = WebApplication.CreateSlimBuilder(new WebApplicationOptions { Args = [] });
builder.Logging.ClearProviders();
builder.Services.Configure<JsonOptions>(o => { o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase; o.SerializerOptions.Converters.Add(new JsonStringEnumConverter()); });
builder.WebHost.ConfigureKestrel(k => k.Listen(System.Net.IPAddress.Loopback, port));
var app = builder.Build();

if (token is not null)
{
	app.Use(async (ctx, next) =>
	{
		var auth = ctx.Request.Headers.Authorization.ToString();
		var q = ctx.Request.Query["token"].ToString();
		if (auth == $"Bearer {token}" || q == token) { await next(); return; }
		ctx.Response.StatusCode = 401;
	});
}

List<LibraryBook> Library() => DbContexts.GetLibrary_Flat_NoTracking(includeParents: true);

app.MapGet("/api/status", () => new StatusDto(
	LibationScaffolding.BuildVersion?.ToString() ?? "?",
	config.LibationFiles.Location,
	config.Books?.PathWithoutPrefix,
	DbContexts.GetIndexableBookCount(),
	scan.Scanning));

app.MapGet("/api/library", () => Library().Select(BookDto.From).ToList());

app.MapGet("/api/library/{asin}", (string asin) =>
	DbContexts.GetLibraryBook_Flat_NoTracking(asin) is { } lb ? Results.Ok(BookDto.From(lb)) : Results.NotFound());

app.MapGet("/api/search", (string? q) =>
{
	if (string.IsNullOrWhiteSpace(q)) return Results.Ok(Array.Empty<string>());
	var rs = SearchEngineCommands.Search(q);
	return Results.Ok(rs.Docs.Select(d => d.ProductId).ToArray());
});

app.MapGet("/api/covers/{pictureId}", (string pictureId, int? size, CancellationToken ct) =>
{
	var ps = size switch { 300 => PictureSize._300x300, 500 => PictureSize._500x500, null or 80 => PictureSize._80x80, _ => PictureSize.Native };
	using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
	cts.CancelAfter(TimeSpan.FromSeconds(15));
	var bytes = PictureStorage.GetPictureSynchronously(new PictureDefinition(pictureId, ps), cts.Token);
	if (bytes.Length == 0) bytes = PictureStorage.GetDefaultImage(ps);
	return Results.Bytes(bytes, "image/jpeg");
});

app.MapGet("/api/accounts", () =>
{
	using var persister = AudibleApiStorage.GetAccountsSettingsPersister();
	return persister.AccountsSettings.GetAll()
		.Select(a => new AccountDto(a.AccountId, a.AccountName, a.Locale?.Name, a.LibraryScan)).ToList();
});

app.MapPost("/api/scan", (ScanRequest? req) =>
{
	if (scan.Scanning) return Results.Conflict(scan);
	Account[] accounts;
	using (var persister = AudibleApiStorage.GetAccountsSettingsPersister())
	{
		var all = persister.AccountsSettings.GetAll();
		accounts = req?.Accounts is { Length: > 0 } names
			? all.Where(a => names.Contains(a.AccountId, StringComparer.OrdinalIgnoreCase) || names.Contains(a.AccountName ?? "", StringComparer.OrdinalIgnoreCase)).ToArray()
			: all.Where(a => a.LibraryScan).ToArray();
	}
	if (accounts.Length == 0) return Results.BadRequest(new { error = "No accounts to scan." });

	_ = Task.Run(async () =>
	{
		try
		{
			var (total, added) = await LibraryCommands.ImportAccountAsync(accounts, allowInteractiveLogin: false);
			scan = new(false, total, added, null);
		}
		catch (Exception ex)
		{
			Serilog.Log.Logger.Error(ex, "Scan failed");
			scan = new(false, null, null, ex.Message);
		}
		hub.Publish("scan", scan);
	});
	return Results.Accepted(value: new ScanStateDto(true, null, null, null));
});
app.MapGet("/api/scan", () => scan);

app.MapGet("/api/queue", () => queue.Snapshot());
app.MapPost("/api/queue/liberate", async (LiberateRequest req) =>
{
	var wanted = req.Asins.ToHashSet(StringComparer.OrdinalIgnoreCase);
	var books = Library().Where(lb => wanted.Contains(lb.Book.AudibleProductId)).ToList();
	if (books.Count == 0) return Results.NotFound(new { error = "No matching books." });
	var queued = await queue.LiberateAsync(books);
	return Results.Ok(new { queued, snapshot = queue.Snapshot() });
});
app.MapPost("/api/queue/cancel", async () => { await queue.CancelAllAsync(); return queue.Snapshot(); });
app.MapPost("/api/queue/{asin}/cancel", async (string asin) => await queue.CancelAsync(asin) ? Results.Ok(queue.Snapshot()) : Results.NotFound());

app.MapGet("/api/events", async (HttpContext ctx) =>
{
	ctx.Response.Headers.ContentType = "text/event-stream";
	ctx.Response.Headers.CacheControl = "no-cache";
	var reader = hub.Subscribe(out var unsubscribe);
	try
	{
		await ctx.Response.WriteAsync($"event: hello\ndata: {JsonSerializer.Serialize(new { version = LibationScaffolding.BuildVersion?.ToString() }, json)}\n\n", ctx.RequestAborted);
		await ctx.Response.WriteAsync($"event: queue\ndata: {JsonSerializer.Serialize(queue.Snapshot(), json)}\n\n", ctx.RequestAborted);
		await ctx.Response.Body.FlushAsync(ctx.RequestAborted);
		await foreach (var frame in reader.ReadAllAsync(ctx.RequestAborted))
		{
			await ctx.Response.WriteAsync(frame, ctx.RequestAborted);
			await ctx.Response.Body.FlushAsync(ctx.RequestAborted);
		}
	}
	catch (OperationCanceledException) { }
	finally { unsubscribe(); }
});

app.MapPost("/api/shutdown", (IHostApplicationLifetime life) => { life.StopApplication(); return Results.Ok(); });

await app.StartAsync();
var url = app.Urls.First();
Console.WriteLine($"LIBATION_HOST_URL={url}");
Console.Out.Flush();
Serilog.Log.Logger.Information("LibationHost listening on {Url}", url);
await app.WaitForShutdownAsync();
return 0;
