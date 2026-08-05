namespace PiNotifyRouteHost.Protocol;

/// <summary>
/// Portable Pi Web instance identity. It is opaque, but every producer and
/// consumer must agree on the same exact ASCII spelling before routing.
/// </summary>
public static class InstanceKeyContract
{
    public const int MinLength = 8;
    public const int MaxLength = ProtocolConstants.MaxOpaqueFieldLength;

    public static bool IsValid(string? value)
    {
        if (value is null || value.Length is < MinLength or > MaxLength)
        {
            return false;
        }

        foreach (var character in value)
        {
            if (!(char.IsAsciiLetterOrDigit(character) ||
                  character is '.' or '_' or '+' or '-'))
            {
                return false;
            }
        }

        return true;
    }
}
