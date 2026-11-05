using System.Collections.Specialized;
using System.ComponentModel;
using DataLayer;
using LibationUiBase.ProcessQueue;

namespace LibationHost;

/// <summary>
/// Owns the one ProcessQueueViewModel and turns its change notifications into throttled
/// "queue" events. The view model does the real work (it is the same class the GUIs bind to).
/// </summary>
public sealed class HostQueue
{
	public ProcessQueueViewModel Vm { get; } = new();
	private readonly EventHub _hub;
	private readonly HashSet<ProcessBookViewModel> _subscribed = new();
	private readonly object _lock = new();
	private int _pending;

	public HostQueue(EventHub hub)
	{
		_hub = hub;
		Vm.Queue.CollectionChanged += OnCollectionChanged;
		Vm.PropertyChanged += (_, _) => Schedule();
		Vm.ProcessStart += (_, b) => Schedule();
		Vm.ProcessEnd += (_, b) => Schedule();
	}

	private void OnCollectionChanged(object? sender, NotifyCollectionChangedEventArgs e)
	{
		lock (_lock)
		{
			foreach (var item in Vm.Queue.GetAllItems())
			{
				if (_subscribed.Add(item))
				{
					item.PropertyChanged += OnItemChanged;
					item.LogWritten += (s, text) => _hub.Publish("log", new { asin = item.LibraryBook.Book.AudibleProductId, text });
				}
			}
		}
		Schedule();
	}

	private void OnItemChanged(object? sender, PropertyChangedEventArgs e) => Schedule();

	/// <summary>Coalesce bursts of notifications into at most ~5 snapshots per second.</summary>
	private void Schedule()
	{
		if (Interlocked.Exchange(ref _pending, 1) == 1)
			return;
		_ = Task.Run(async () =>
		{
			await Task.Delay(200);
			Interlocked.Exchange(ref _pending, 0);
			_hub.Publish("queue", Snapshot());
		});
	}

	public QueueSnapshotDto Snapshot()
	{
		var items = Vm.Queue.GetAllItems().Select(QueueItemDto.From).ToList();
		return new QueueSnapshotDto(
			Running: Vm.Running,
			QueuedCount: Vm.QueuedCount,
			CompletedCount: Vm.CompletedCount,
			ErrorCount: Vm.ErrorCount,
			Progress: Vm.Queue.Count == 0 ? 0 : Vm.Progress,
			MaxConcurrentDownloads: Vm.MaxConcurrentDownloads,
			Items: items);
	}

	public Task<bool> LiberateAsync(IList<LibraryBook> books) => Vm.QueueDownloadDecryptAsync(books);
	public Task CancelAllAsync() => Vm.CancelAllAsync();

	public async Task<bool> CancelAsync(string asin)
	{
		var item = Vm.Queue.GetAllItems().FirstOrDefault(i => i.LibraryBook.Book.AudibleProductId == asin);
		if (item is null) return false;
		if (item.Queued) { Vm.Queue.RemoveQueued(item); Schedule(); return true; }
		if (item.IsDownloading) { await item.CancelAsync(); return true; }
		Vm.Queue.RemoveCompleted(item);
		Schedule();
		return true;
	}
}
