using System.Collections.Concurrent;

namespace LibationHost;

/// <summary>
/// The view models in LibationUiBase were written for a UI thread: they capture
/// SynchronizationContext.Current and marshal every notification through it. The host has no
/// UI, so this stands in for one: a single dedicated thread that runs posted callbacks in order.
/// </summary>
public sealed class HostSyncContext : SynchronizationContext
{
	private readonly BlockingCollection<(SendOrPostCallback cb, object? state, ManualResetEventSlim? done)> _work = new();
	private readonly Thread _thread;

	public HostSyncContext()
	{
		_thread = new Thread(Run) { IsBackground = true, Name = "LibationHost.Sync" };
		_thread.Start();
	}

	private void Run()
	{
		SetSynchronizationContext(this);
		foreach (var (cb, state, done) in _work.GetConsumingEnumerable())
		{
			try { cb(state); }
			catch (Exception ex) { Serilog.Log.Logger.Error(ex, "Unhandled exception on host sync thread"); }
			finally { done?.Set(); }
		}
	}

	public override void Post(SendOrPostCallback d, object? state) => _work.Add((d, state, null));

	public override void Send(SendOrPostCallback d, object? state)
	{
		if (Thread.CurrentThread == _thread) { d(state); return; }
		using var done = new ManualResetEventSlim();
		_work.Add((d, state, done));
		done.Wait();
	}

	public override SynchronizationContext CreateCopy() => this;
}
