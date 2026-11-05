using DataLayer;
using LibationUiBase.ProcessQueue;

namespace LibationHost;

public record SeriesLinkDto(string SeriesAsin, string? Name, string? Order, float Index);

public record RatingDto(float Overall, float Performance, float Story)
{
	public static RatingDto From(Rating r) => new(r.OverallRating, r.PerformanceRating, r.StoryRating);
}

/// <summary>One row of the library, flattened. Formatting (dates, lengths, icons) is the front end's job.</summary>
public record BookDto(
	string Asin,
	string Title,
	string Subtitle,
	string TitleWithSubtitle,
	string Description,
	string Authors,
	string Narrators,
	string? Publisher,
	int LengthMinutes,
	string ContentType,
	string Locale,
	string? PictureId,
	bool IsAbridged,
	bool IsSpatial,
	DateTime? DatePublished,
	string? Language,
	string Account,
	DateTime DateAdded,
	DateTime? IncludedUntil,
	bool IsAudiblePlus,
	bool AbsentFromLastScan,
	string BookStatus,
	string? PdfStatus,
	bool AudioExists,
	bool NeedsBookDownload,
	bool NeedsPdfDownload,
	string Tags,
	RatingDto MyRating,
	RatingDto ProductRating,
	DateTime? LastDownloaded,
	string? LastDownloadedVersion,
	IReadOnlyList<SeriesLinkDto> Series)
{
	public static BookDto From(LibraryBook lb)
	{
		var b = lb.Book;
		var udi = b.UserDefinedItem;
		return new BookDto(
			Asin: b.AudibleProductId,
			Title: b.Title,
			Subtitle: b.Subtitle,
			TitleWithSubtitle: b.TitleWithSubtitle,
			Description: b.Description,
			Authors: b.AuthorNames,
			Narrators: b.NarratorNames,
			Publisher: b.Publisher,
			LengthMinutes: b.LengthInMinutes,
			ContentType: b.ContentType.ToString(),
			Locale: b.Locale,
			PictureId: b.PictureId ?? b.PictureLarge,
			IsAbridged: b.IsAbridged,
			IsSpatial: b.IsSpatial,
			DatePublished: b.DatePublished,
			Language: b.Language,
			Account: lb.Account,
			DateAdded: lb.DateAdded,
			IncludedUntil: lb.IncludedUntil,
			IsAudiblePlus: lb.IsAudiblePlus,
			AbsentFromLastScan: lb.AbsentFromLastScan,
			BookStatus: udi.BookStatus.ToString(),
			PdfStatus: udi.PdfStatus?.ToString(),
			AudioExists: b.AudioExists,
			NeedsBookDownload: lb.NeedsBookDownload,
			NeedsPdfDownload: lb.NeedsPdfDownload,
			Tags: udi.Tags,
			MyRating: RatingDto.From(udi.Rating),
			ProductRating: RatingDto.From(b.Rating),
			LastDownloaded: udi.LastDownloaded,
			LastDownloadedVersion: udi.LastDownloadedVersion?.ToString(),
			Series: b.SeriesLink.Select(sl => new SeriesLinkDto(sl.Series.AudibleSeriesId, sl.Series.Name, sl.Order, sl.Index)).ToList());
	}
}

public record AccountDto(string AccountId, string? AccountName, string? Locale, bool LibraryScan, IReadOnlyList<string> AdditionalLocales, bool HasTokens)
{
	public static AccountDto From(AudibleUtilities.Account a) => new(
		a.AccountId, a.AccountName, a.Locale?.Name, a.LibraryScan,
		a.AdditionalLocales.Select(l => l.Name).ToList(),
		a.IdentityTokens?.IsValid == true);
}

public record LocaleDto(string Name, string CountryCode, bool WithUsername);
public record AddAccountRequest(string AccountId, string Locale, string? AccountName, bool LibraryScan = true);
public record UpdateAccountRequest(string? AccountName, bool? LibraryScan);
public record CompleteLoginRequest(string ResponseUrl);
public record SignInResultDto(string AccountId, string? Locale, bool Ok, string? Error);

public record QueueItemDto(
	string Asin,
	string? Title,
	string? Author,
	string? Narrator,
	string? PictureId,
	string Status,
	string Result,
	string StatusText,
	int Progress,
	double EtaSeconds)
{
	public static QueueItemDto From(ProcessBookViewModel vm) => new(
		Asin: vm.LibraryBook.Book.AudibleProductId,
		Title: vm.Title,
		Author: vm.Author,
		Narrator: vm.Narrator,
		PictureId: vm.LibraryBook.Book.PictureId ?? vm.LibraryBook.Book.PictureLarge,
		Status: vm.Status.ToString(),
		Result: vm.Result.ToString(),
		StatusText: vm.StatusText,
		Progress: vm.Progress,
		EtaSeconds: vm.TimeRemaining.TotalSeconds);
}

public record QueueSnapshotDto(
	bool Running,
	int QueuedCount,
	int CompletedCount,
	int ErrorCount,
	double Progress,
	int MaxConcurrentDownloads,
	IReadOnlyList<QueueItemDto> Items);

public record ScanStateDto(bool Scanning, int? TotalProcessed, int? NewBooks, string? Error);

public record AlertDto(string Caption, string Message, string Buttons, string Icon);

public record StatusDto(string Version, string LibationFiles, string? BooksDirectory, int BookCount, bool Scanning);

public record LiberateRequest(string[] Asins);
public record ScanRequest(string[]? Accounts);

public record BookDetailsDto(BookDto Book, IReadOnlyList<string> Categories, string AudibleUrl, bool HasPdf, string? FilePath)
{
	public static BookDetailsDto From(LibraryBook lb)
	{
		var locale = AudibleApi.Localization.Get(lb.Book.Locale);
		var domain = string.IsNullOrEmpty(locale.TopDomain) ? "com" : locale.TopDomain;
		string? path = null;
		try { path = lb.Book.AudioExists ? LibationFileManager.AudibleFileStorage.Audio.GetPath(lb.Book.AudibleProductId)?.PathWithoutPrefix : null; }
		catch (Exception ex) { Serilog.Log.Logger.Debug(ex, "No file path for {Asin}", lb.Book.AudibleProductId); }
		return new BookDetailsDto(
			BookDto.From(lb),
			lb.Book.LowestCategoryNames().Where(c => !string.IsNullOrWhiteSpace(c)).ToList(),
			$"https://www.audible.{domain}/pd/{lb.Book.AudibleProductId}",
			lb.Book.HasPdf,
			path);
	}
}

public record UserItemUpdateRequest(string[] Asins, string? Tags, string? BookStatus, string? PdfStatus, RatingDto? Rating);
public record AsinsRequest(string[] Asins);
