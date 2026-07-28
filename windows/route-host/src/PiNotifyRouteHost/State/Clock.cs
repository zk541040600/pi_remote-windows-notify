namespace PiNotifyRouteHost.State;

public interface IClock
{
    long UtcNowMs { get; }
}

public sealed class SystemClock : IClock
{
    public long UtcNowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
}

/// <summary>Deterministic clock for tests.</summary>
public sealed class FakeClock : IClock
{
    private long _utcNowMs;

    public FakeClock(long startMs = 1_700_000_000_000)
    {
        _utcNowMs = startMs;
    }

    public long UtcNowMs => _utcNowMs;

    public void AdvanceMs(long deltaMs)
    {
        if (deltaMs < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(deltaMs));
        }

        _utcNowMs += deltaMs;
    }

    public void SetMs(long utcNowMs) => _utcNowMs = utcNowMs;
}
