using System.Security.Cryptography;
using System.Text;
using PiNotifyRouteHost.Protocol;
using Xunit;

namespace PiNotifyRouteHost.Tests;

public class RoutingKeyTests
{
    [Fact]
    public void Compute_matches_manual_sha256_of_domain_separated_fields()
    {
        const string instanceKey = "11111111-2222-3333-4444-555555555555";
        const string rawSessionId = "session-alpha-example";

        var expected = ManualCompute(instanceKey, rawSessionId);
        var actual = RoutingKey.Compute(instanceKey, rawSessionId);

        Assert.Equal(expected, actual);
        Assert.Equal(64, actual.Length);
        Assert.Equal(actual, actual.ToLowerInvariant());
    }

    [Fact]
    public void Compute_is_stable_for_same_inputs()
    {
        const string instanceKey = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        const string session = "stable-session";

        var a = RoutingKey.Compute(instanceKey, session);
        var b = RoutingKey.Compute(instanceKey, session);
        Assert.Equal(a, b);
    }

    [Fact]
    public void Compute_preserves_printable_edge_whitespace()
    {
        Assert.Equal(
            "687e3332585d90c6d0a6d0f615738fa80e251932ceee0acb061a24fada3b3433",
            RoutingKey.Compute(
                "11111111-2222-3333-4444-555555555555",
                " padded "));
    }

    [Fact]
    public void Compute_accepts_a_valid_surrogate_pair()
    {
        Assert.Equal(
            "18a9bdd83e4a6bf02686680349a490077bd4db3cb05e418e04d9225447df3ba0",
            RoutingKey.Compute(
                "11111111-2222-3333-4444-555555555555",
                "valid-🚀"));
    }

    [Fact]
    public void Different_sessions_produce_different_keys()
    {
        const string instanceKey = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee";
        var k1 = RoutingKey.Compute(instanceKey, "sess-one");
        var k2 = RoutingKey.Compute(instanceKey, "sess-two");
        Assert.NotEqual(k1, k2);
    }

    [Fact]
    public void Different_instances_produce_different_keys()
    {
        const string session = "same-session-id";
        var k1 = RoutingKey.Compute("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", session);
        var k2 = RoutingKey.Compute("ffffffff-0000-1111-2222-333333333333", session);
        Assert.NotEqual(k1, k2);
    }

    [Theory]
    [InlineData(null, "s")]
    [InlineData("", "s")]
    [InlineData("   ", "s")]
    [InlineData("i", null)]
    [InlineData("i", "")]
    [InlineData("i", "  ")]
    public void Compute_rejects_missing_fields(string? instanceKey, string? rawSessionId)
    {
        Assert.ThrowsAny<ArgumentException>(() => RoutingKey.Compute(instanceKey!, rawSessionId!));
    }

    [Fact]
    public void Compute_rejects_non_portable_session_identity_before_hashing()
    {
        const string instanceKey = "11111111-2222-3333-4444-555555555555";
        var invalidSessions = new[]
        {
            "bad\u0085id",
            "\uFEFF",
            "\uD800",
            "\uDC00",
            "https://example.invalid/session",
            new string('x', 257)
        };

        foreach (var sessionId in invalidSessions)
        {
            Assert.ThrowsAny<ArgumentException>(() => RoutingKey.Compute(instanceKey, sessionId));
        }
    }

    [Theory]
    [InlineData("short")]
    [InlineData("bad/path")]
    [InlineData("bad=value")]
    [InlineData(" padded-instance ")]
    public void Compute_rejects_non_portable_instance_identity_before_hashing(
        string instanceKey)
    {
        Assert.ThrowsAny<ArgumentException>(
            () => RoutingKey.Compute(instanceKey, "session"));
    }

    [Fact]
    public void Compute_rejects_overlong_instance_identity_before_hashing()
    {
        Assert.ThrowsAny<ArgumentException>(
            () => RoutingKey.Compute(new string('x', 129), "session"));
    }

    [Fact]
    public void Fingerprint_is_first_12_hex_chars()
    {
        var key = RoutingKey.Compute("inst-key-001", "sess-001");
        Assert.Equal(key[..12], RoutingKey.Fingerprint(key));
    }

    [Fact]
    public void Domain_separator_prevents_trivial_concatenation_collision()
    {
        // The two concatenations are both "abcdefghij"; the NUL separators keep them distinct.
        var k1 = RoutingKey.Compute("abcdefgh", "ij");
        var k2 = RoutingKey.Compute("abcdefghi", "j");
        Assert.NotEqual(k1, k2);
    }

    private static string ManualCompute(string instanceKey, string rawSessionId)
    {
        var domain = Encoding.UTF8.GetBytes(ProtocolConstants.RoutingKeyDomain + "\0");
        var inst = Encoding.UTF8.GetBytes(instanceKey);
        var sess = Encoding.UTF8.GetBytes(rawSessionId);
        var payload = new byte[domain.Length + inst.Length + 1 + sess.Length];
        Buffer.BlockCopy(domain, 0, payload, 0, domain.Length);
        Buffer.BlockCopy(inst, 0, payload, domain.Length, inst.Length);
        payload[domain.Length + inst.Length] = 0;
        Buffer.BlockCopy(sess, 0, payload, domain.Length + inst.Length + 1, sess.Length);
        return Convert.ToHexString(SHA256.HashData(payload)).ToLowerInvariant();
    }
}
