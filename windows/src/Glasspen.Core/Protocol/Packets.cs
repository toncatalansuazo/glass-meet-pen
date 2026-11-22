using System.Buffers.Binary;

namespace Glasspen.Core.Protocol;

/// <summary>Frame kinds inside an encrypted channel frame.</summary>
public enum FrameKind : byte { Message = 0, Video = 1, Detail = 2 }

/// <summary>
/// A JPEG still of part of the display. <see cref="RequestId"/> 0 with the full rect is a whole-screen
/// frame: the Windows app sends these instead of H.264 video (see docs/protocol.md §8).
/// </summary>
public sealed record DetailPacket(NormRect Rect, uint RequestId, byte[] Jpeg)
{
    public const uint FullFrameId = 0;

    public byte[] Encode()
    {
        var data = new byte[20 + Jpeg.Length];
        var s = data.AsSpan();
        BinaryPrimitives.WriteSingleBigEndian(s, Rect.X);
        BinaryPrimitives.WriteSingleBigEndian(s[4..], Rect.Y);
        BinaryPrimitives.WriteSingleBigEndian(s[8..], Rect.W);
        BinaryPrimitives.WriteSingleBigEndian(s[12..], Rect.H);
        BinaryPrimitives.WriteUInt32BigEndian(s[16..], RequestId);
        Jpeg.CopyTo(s[20..]);
        return data;
    }

    public static DetailPacket? Decode(ReadOnlySpan<byte> d) => d.Length < 20 ? null :
        new DetailPacket(new NormRect(BinaryPrimitives.ReadSingleBigEndian(d), BinaryPrimitives.ReadSingleBigEndian(d[4..]),
                                      BinaryPrimitives.ReadSingleBigEndian(d[8..]), BinaryPrimitives.ReadSingleBigEndian(d[12..])),
                         BinaryPrimitives.ReadUInt32BigEndian(d[16..]), d[20..].ToArray());
}
