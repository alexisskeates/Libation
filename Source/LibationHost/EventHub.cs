using System.Text.Json;
using System.Threading.Channels;

namespace LibationHost;

/// <summary>Fan-out of server-sent events to every connected client.</summary>
public sealed class EventHub
{
	private readonly object _lock = new();
	private readonly List<Channel<string>> _clients = new();
	private readonly JsonSerializerOptions _json;

	public EventHub(JsonSerializerOptions json) => _json = json;

	public ChannelReader<string> Subscribe(out Action unsubscribe)
	{
		var ch = Channel.CreateBounded<string>(new BoundedChannelOptions(256) { FullMode = BoundedChannelFullMode.DropOldest });
		lock (_lock) _clients.Add(ch);
		unsubscribe = () => { lock (_lock) _clients.Remove(ch); ch.Writer.TryComplete(); };
		return ch.Reader;
	}

	public void Publish(string eventName, object payload)
	{
		var frame = $"event: {eventName}\ndata: {JsonSerializer.Serialize(payload, _json)}\n\n";
		Channel<string>[] targets;
		lock (_lock) targets = _clients.ToArray();
		foreach (var c in targets)
			c.Writer.TryWrite(frame);
	}
}
