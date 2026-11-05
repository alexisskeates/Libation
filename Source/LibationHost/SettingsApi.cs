using System.ComponentModel;
using System.Reflection;
using System.Text.Json;
using Dinah.Core;
using FileManager;
using LibationFileManager;

namespace LibationHost;

public record SettingOptionDto(string Value, string Label);
public record SettingDto(string Name, string Group, string Type, object? Value, string Description, string Help, IReadOnlyList<SettingOptionDto>? Options);

/// <summary>
/// Reflection over <see cref="Configuration"/>: every public settable property with a [Description]
/// and a simple type is exposed, grouped the way the GUIs' settings tabs group them. Writes go
/// straight through the property setter, which persists immediately, exactly as the GUIs do.
/// </summary>
public static class SettingsApi
{
	// Same tabs as LibationAvalonia/Controls/Settings. Order here is display order.
	private static readonly (string group, string[] names)[] Groups =
	[
		("Important", [
			nameof(Configuration.Books), nameof(Configuration.SavePodcastsToParentFolder), nameof(Configuration.OverwriteExisting),
			nameof(Configuration.CreationTime), nameof(Configuration.LastWriteTime), nameof(Configuration.DeviceRegistrationKind),
			nameof(Configuration.CheckForUpgradesAtStartup), nameof(Configuration.LogLevel)]),
		("Import", [
			nameof(Configuration.AutoScan), nameof(Configuration.AutoDownloadEpisodes), nameof(Configuration.ShowImportedStats),
			nameof(Configuration.ImportEpisodes), nameof(Configuration.ImportPlusTitles), nameof(Configuration.DownloadEpisodes)]),
		("Download & Decrypt", [
			nameof(Configuration.InProgress), nameof(Configuration.MaxConcurrentDownloads), nameof(Configuration.DownloadSpeedLimit),
			nameof(Configuration.DailyDownloadLimit), nameof(Configuration.DailyDownloadLimitQuantity), nameof(Configuration.DailyDownloadLimitUnit),
			nameof(Configuration.BadBook), nameof(Configuration.UseCoverAsFolderIcon), nameof(Configuration.SaveMetadataToFile),
			nameof(Configuration.FolderTemplate), nameof(Configuration.FileTemplate), nameof(Configuration.ChapterFileTemplate)]),
		("Audio", [
			nameof(Configuration.FileDownloadQuality), nameof(Configuration.UseWidevine), nameof(Configuration.Request_xHE_AAC),
			nameof(Configuration.AllowLibationFixup), nameof(Configuration.CreateCueSheet), nameof(Configuration.DownloadCoverArt),
			nameof(Configuration.DownloadClipsBookmarks), nameof(Configuration.ClipsBookmarksFileFormat), nameof(Configuration.RetainAaxFile),
			nameof(Configuration.StripUnabridged), nameof(Configuration.StripAudibleBrandAudio), nameof(Configuration.MergeOpeningAndEndCredits),
			nameof(Configuration.SplitFilesByChapter), nameof(Configuration.MinimumFileDuration), nameof(Configuration.CombineNestedChapterTitles),
			nameof(Configuration.ChapterTitleTemplate), nameof(Configuration.MoveMoovToBeginning), nameof(Configuration.MaxSampleRate),
			nameof(Configuration.DecryptToLossy), nameof(Configuration.LameTargetBitrate), nameof(Configuration.LameBitrate),
			nameof(Configuration.LameConstantBitrate), nameof(Configuration.LameMatchSourceBR), nameof(Configuration.LameVBRQuality),
			nameof(Configuration.LameEncoderQuality), nameof(Configuration.LameDownsampleMono)]),
		("Audiobookshelf", [
			nameof(Configuration.AudiobookshelfEnabled), nameof(Configuration.AudiobookshelfIncludePdfs), nameof(Configuration.AudiobookshelfServerUrl),
			nameof(Configuration.AudiobookshelfApiToken), nameof(Configuration.AudiobookshelfLibraryId), nameof(Configuration.AudiobookshelfFolderId)]),
	];

	private static readonly Dictionary<string, PropertyInfo> Props = typeof(Configuration)
		.GetProperties(BindingFlags.Public | BindingFlags.Instance)
		.Where(p => p.CanRead && p.CanWrite)
		.ToDictionary(p => p.Name);

	public static List<SettingDto> GetAll(Configuration config)
	{
		var list = new List<SettingDto>();
		foreach (var (group, names) in Groups)
			foreach (var name in names)
				if (Props.TryGetValue(name, out var p))
					list.Add(Describe(config, p, group));
		return list;
	}

	private static SettingDto Describe(Configuration config, PropertyInfo p, string group)
	{
		var t = Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType;
		var raw = p.GetValue(config);
		string type; object? value = raw; IReadOnlyList<SettingOptionDto>? options = null;
		if (t == typeof(bool)) type = "bool";
		else if (t == typeof(int) || t == typeof(long)) type = "int";
		else if (t == typeof(float) || t == typeof(double)) type = "float";
		else if (t.IsEnum)
		{
			type = "enum";
			value = raw?.ToString();
			options = Enum.GetValues(t).Cast<Enum>()
				.Select(e => new SettingOptionDto(e.ToString(), e.GetDescription() ?? e.ToString()))
				.ToList();
		}
		else if (t == typeof(LongPath)) { type = "path"; value = (raw as LongPath)?.PathWithoutPrefix; }
		else if (p.Name == nameof(Configuration.InProgress)) { type = "path"; }
		else type = p.Name.Contains("Token", StringComparison.Ordinal) ? "secret" : "string";

		var description = p.GetCustomAttribute<DescriptionAttribute>()?.Description ?? Configuration.GetDescription(p.Name);
		return new SettingDto(p.Name, group, type, value, description, Configuration.GetHelpText(p.Name), options);
	}

	/// <summary>Applies each entry; returns the names that could not be applied with a reason.</summary>
	public static Dictionary<string, string> Apply(Configuration config, JsonElement body)
	{
		var errors = new Dictionary<string, string>();
		if (body.ValueKind != JsonValueKind.Object) { errors["body"] = "Expected a JSON object of setting name → value."; return errors; }
		var allowed = Groups.SelectMany(g => g.names).ToHashSet();
		foreach (var entry in body.EnumerateObject())
		{
			if (!allowed.Contains(entry.Name) || !Props.TryGetValue(entry.Name, out var p)) { errors[entry.Name] = "Unknown or read-only setting."; continue; }
			try
			{
				p.SetValue(config, Convert(p, entry.Value));
			}
			catch (Exception ex)
			{
				errors[entry.Name] = ex.InnerException?.Message ?? ex.Message;
			}
		}
		return errors;
	}

	private static object? Convert(PropertyInfo p, JsonElement v)
	{
		var t = Nullable.GetUnderlyingType(p.PropertyType) ?? p.PropertyType;
		if (v.ValueKind == JsonValueKind.Null) return t == typeof(LongPath) || t == typeof(string) ? null : throw new ArgumentException("null not allowed");
		if (t == typeof(bool)) return v.ValueKind == JsonValueKind.String ? bool.Parse(v.GetString()!) : v.GetBoolean();
		if (t == typeof(int)) return v.ValueKind == JsonValueKind.String ? int.Parse(v.GetString()!) : v.GetInt32();
		if (t == typeof(long)) return v.ValueKind == JsonValueKind.String ? long.Parse(v.GetString()!) : v.GetInt64();
		if (t == typeof(float)) return v.ValueKind == JsonValueKind.String ? float.Parse(v.GetString()!) : v.GetSingle();
		if (t == typeof(double)) return v.ValueKind == JsonValueKind.String ? double.Parse(v.GetString()!) : v.GetDouble();
		if (t.IsEnum) return Enum.Parse(t, v.GetString()!, ignoreCase: true);
		if (t == typeof(LongPath)) return (LongPath)v.GetString()!;
		if (t == typeof(string)) return v.GetString();
		throw new NotSupportedException($"Cannot set a {t.Name}");
	}
}
