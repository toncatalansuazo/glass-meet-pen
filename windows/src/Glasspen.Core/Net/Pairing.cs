using System.Security.Cryptography;
using System.Text;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Math.EC.Rfc7748;

namespace Glasspen.Core.Net;

/// <summary>How a phone proves it may connect (docs/protocol.md §3).</summary>
public enum AuthMode { Token, Confirm }

/// <summary>The computer's long-term pairing secret: 16 random bytes, base64url without padding.</summary>
public sealed record PairingSecret(string Token)
{
    public static PairingSecret Generate() => new(Base64Url(RandomNumberGenerator.GetBytes(16)));

    /// <summary><c>paintscreen://pair?svc=&lt;name&gt;&amp;t=&lt;token&gt;&amp;h=&lt;host&gt;&amp;p=&lt;port&gt;</c>, shown as a QR code.</summary>
    public string PairingUrl(string serviceName, string? host, ushort port)
    {
        var query = $"svc={Uri.EscapeDataString(serviceName)}&t={Uri.EscapeDataString(Token)}";
        if (host is not null) query += $"&h={Uri.EscapeDataString(host)}";
        return $"paintscreen://pair?{query}&p={port}";
    }

    public static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).Replace('+', '-').Replace('/', '_').TrimEnd('=');
}

/// <summary>Keys for one handshake: fresh X25519 per connection; both sides prove they derived the same key.</summary>
public sealed class HandshakeKeys
{
    public byte[] Key { get; }
    public byte[] Transcript { get; }

    public HandshakeKeys(byte[] shared, string? token, AuthMode mode, byte[] clientNonce, byte[] serverNonce, byte[] clientPub, byte[] serverPub)
    {
        Transcript = SHA256.HashData(Concat(Encoding.UTF8.GetBytes($"glasspen-v2-{Wire(mode)}"), clientNonce, serverNonce, clientPub, serverPub));
        var ikm = token is null ? shared : Concat(shared, Encoding.UTF8.GetBytes(token));
        Key = HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, 32, Transcript, "glasspen-v2-key"u8.ToArray());
    }

    public byte[] ClientProof => Mac("client");
    public byte[] ServerProof => Mac("server");
    public byte[] ClientToServer => Derive("c2s", 32);
    public byte[] ServerToClient => Derive("s2c", 32);

    /// <summary>The 6 digits both screens show in confirm mode.</summary>
    public string ConfirmCode
    {
        get
        {
            var b = Derive("sas", 4);
            var n = (uint)(b[0] << 24 | b[1] << 16 | b[2] << 8 | b[3]);
            return (n % 1_000_000).ToString("D6");
        }
    }

    public bool IsValidClientProof(byte[] mac) => CryptographicOperations.FixedTimeEquals(mac, ClientProof);
    public bool IsValidServerProof(byte[] mac) => CryptographicOperations.FixedTimeEquals(mac, ServerProof);

    private byte[] Mac(string label) => HMACSHA256.HashData(Key, Concat(Encoding.UTF8.GetBytes(label), Transcript));
    private byte[] Derive(string info, int length) => HKDF.DeriveKey(HashAlgorithmName.SHA256, Key, length, Transcript, Encoding.UTF8.GetBytes(info));

    public static string Wire(AuthMode mode) => mode == AuthMode.Token ? "token" : "confirm";

    internal static byte[] Concat(params byte[][] parts)
    {
        var result = new byte[parts.Sum(p => p.Length)];
        var offset = 0;
        foreach (var p in parts) { p.CopyTo(result, offset); offset += p.Length; }
        return result;
    }
}

/// <summary>An X25519 key pair.</summary>
public sealed class KeyPair
{
    public byte[] Private { get; }
    public byte[] Public { get; } = new byte[32];

    public KeyPair(byte[]? privateKey = null)
    {
        Private = privateKey ?? RandomNumberGenerator.GetBytes(32);
        X25519.GeneratePublicKey(Private, 0, Public, 0);
    }

    /// <summary>Null when the peer key is invalid (the result would be all zeros).</summary>
    public byte[]? Agree(byte[] peerPublic)
    {
        if (peerPublic.Length != 32) return null;
        var shared = new byte[32];
        return X25519.CalculateAgreement(Private, 0, peerPublic, 0, shared, 0) ? shared : null;
    }
}

public static class Handshake
{
    public static byte[] RandomNonce() => RandomNumberGenerator.GetBytes(32);

    public static byte[] Commitment(byte[] pub) => SHA256.HashData(HandshakeKeys.Concat("glasspen-v2-commit"u8.ToArray(), pub));

    /// <summary>A phone's name is untrusted: one line of printable text, at most 40 characters.</summary>
    public static string DisplayName(string? raw)
    {
        var name = new string((raw ?? "").Where(c => !char.IsControl(c) && c != (char)0x2028 && c != (char)0x2029).ToArray()).Trim();
        return name.Length == 0 ? "Unknown device" : name.Length > 40 ? name[..40] : name;
    }

    /// <summary>"123 456".</summary>
    public static string DisplayCode(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;
}

/// <summary>ChaCha20-Poly1305 for one direction; the nonce is a frame counter, so replayed or dropped frames fail.</summary>
public sealed class FrameCipher(byte[] key)
{
    private ulong _counter;

    private byte[] Nonce()
    {
        var n = new byte[12];
        System.Buffers.Binary.BinaryPrimitives.WriteUInt64BigEndian(n.AsSpan(4), _counter);
        return n;
    }

    public byte[] Seal(byte[] plaintext) => Seal([], plaintext, headroom: 0);

    /// <summary>
    /// Seals <paramref name="head"/> followed by <paramref name="body"/> without joining them first, into a
    /// new buffer that starts with <paramref name="headroom"/> free bytes (room for the length prefix).
    /// </summary>
    public byte[] Seal(ReadOnlySpan<byte> head, ReadOnlySpan<byte> body, int headroom)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(true, new AeadParameters(new KeyParameter(key), 128, Nonce()));
        var output = new byte[headroom + cipher.GetOutputSize(head.Length + body.Length)];
        var span = output.AsSpan(headroom);
        var len = cipher.ProcessBytes(head, span);
        len += cipher.ProcessBytes(body, span[len..]);
        cipher.DoFinal(span[len..]);
        _counter++;
        return output;
    }

    /// <summary>Throws <see cref="CryptographicException"/> when the frame doesn't authenticate.</summary>
    public byte[] Open(byte[] sealedFrame)
    {
        if (sealedFrame.Length < 16) throw new CryptographicException("frame too short");
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        cipher.Init(false, new AeadParameters(new KeyParameter(key), 128, Nonce()));
        var output = new byte[cipher.GetOutputSize(sealedFrame.Length)];
        try
        {
            var len = cipher.ProcessBytes(sealedFrame, 0, sealedFrame.Length, output, 0);
            cipher.DoFinal(output, len);
        }
        catch (Org.BouncyCastle.Crypto.InvalidCipherTextException e)
        {
            throw new CryptographicException("frame failed to authenticate", e);
        }
        _counter++;
        return output;
    }
}

/// <summary>
/// Handshakes per remote host, counted when they start. A host may have at most <c>maxFailures</c> open
/// attempts plus recent failures; failures are forgotten <c>lockout</c> after the last one, and the
/// <c>maxFailures</c>-th failure locks the host for <c>lockout</c>. Thread-safe.
/// </summary>
public sealed class FailureLimiter(int maxFailures = 5, TimeSpan? lockout = null)
{
    private sealed class Entry { public int Count; public DateTime Last = DateTime.MinValue; public DateTime? LockedUntil; }

    private readonly TimeSpan _lockout = lockout ?? TimeSpan.FromSeconds(30);
    private readonly Dictionary<string, Entry> _failures = new();
    private readonly Dictionary<string, int> _inFlight = new();
    private readonly object _lock = new();

    public bool IsLocked(string host, DateTime? now = null)
    {
        lock (_lock) return Recent(host, now ?? DateTime.UtcNow)?.LockedUntil is { } until && until > (now ?? DateTime.UtcNow);
    }

    public bool Begin(string host, DateTime? now = null)
    {
        lock (_lock)
        {
            var t = now ?? DateTime.UtcNow;
            var entry = Recent(host, t);
            if (entry is null) _failures.Remove(host);
            if (entry?.LockedUntil is { } until && until > t) return false;
            var open = _inFlight.GetValueOrDefault(host);
            if (open + (entry?.Count ?? 0) >= maxFailures) return false;
            _inFlight[host] = open + 1;
            return true;
        }
    }

    public void Finish(string host, bool success, DateTime? now = null)
    {
        lock (_lock)
        {
            var open = _inFlight.GetValueOrDefault(host) - 1;
            if (open > 0) _inFlight[host] = open; else _inFlight.Remove(host);
            if (success) { _failures.Remove(host); return; }
            var t = now ?? DateTime.UtcNow;
            var entry = Recent(host, t) ?? new Entry();
            entry.Count++;
            entry.Last = t;
            if (entry.Count >= maxFailures) { entry.LockedUntil = t + _lockout; entry.Count = 0; }
            _failures[host] = entry;
        }
    }

    private Entry? Recent(string host, DateTime now)
    {
        if (!_failures.TryGetValue(host, out var e)) return null;
        if (e.LockedUntil is { } until) return until > now ? e : null;
        return now - e.Last < _lockout ? e : null;
    }
}
