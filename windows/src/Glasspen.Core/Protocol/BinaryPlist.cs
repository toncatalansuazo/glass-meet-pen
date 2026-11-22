using System.Buffers.Binary;
using System.Text;

namespace Glasspen.Core.Protocol;

/// <summary>
/// Apple binary property lists ("bplist00"), the format Swift's PropertyListEncoder uses for every
/// message. Values: <see cref="Dictionary{TKey,TValue}"/> (string keys), <see cref="List{T}"/> of object,
/// string, long, double, <see cref="PlistReal32"/>, bool, byte[] and <see cref="DateTime"/> (UTC).
/// Decoded containers may be shared between references: treat what <see cref="Read"/> returns as read-only.
/// </summary>
public static class BinaryPlist
{
    private static readonly DateTime AppleEpoch = new(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc);

    // MARK: Reading

    /// <summary>Throws <see cref="FormatException"/> for anything malformed.</summary>
    public static object Read(ReadOnlySpan<byte> data)
    {
        if (data.Length < 40 || !data[..8].SequenceEqual("bplist00"u8)) throw new FormatException("not a binary plist");
        try
        {
            var trailer = data[^32..];
            int offsetSize = trailer[6], refSize = trailer[7];
            var count = checked((int)BinaryPrimitives.ReadUInt64BigEndian(trailer[8..]));
            var top = checked((int)BinaryPrimitives.ReadUInt64BigEndian(trailer[16..]));
            var tableStart = checked((int)BinaryPrimitives.ReadUInt64BigEndian(trailer[24..]));
            if (count <= 0 || count > 1_000_000 || offsetSize is < 1 or > 8 || refSize is < 1 or > 8) throw new FormatException("bad trailer");
            if (tableStart < 8 || tableStart > data.Length - 32) throw new FormatException("bad offset table");
            var offsets = new int[count];
            for (var i = 0; i < count; i++)
            {
                offsets[i] = checked((int)ReadUInt(data, tableStart + i * offsetSize, offsetSize));
                if (offsets[i] < 8 || offsets[i] >= tableStart) throw new FormatException("object outside the object area");
            }
            // Objects live between the header and the offset table: reads never run into the table or trailer.
            return new Reader(data[..tableStart].ToArray(), offsets, refSize).Object(top, depth: 0);
        }
        catch (Exception e) when (e is IndexOutOfRangeException or ArgumentOutOfRangeException or OverflowException)
        {
            throw new FormatException("truncated or corrupt plist", e);
        }
    }

    /// <summary>
    /// Each object is decoded once and shared by every reference to it, so a crafted plist that
    /// references the same container many times can't make decoding grow exponentially.
    /// </summary>
    private sealed class Reader(byte[] data, int[] offsets, int refSize)
    {
        private readonly object?[] _decoded = new object?[offsets.Length];

        public object Object(int index, int depth)
        {
            if (depth > 64 || (uint)index >= offsets.Length) throw new FormatException("bad object reference");
            return _decoded[index] ??= Decode(offsets[index], depth);
        }

        private object Decode(int pos, int depth)
        {
            var marker = data[pos];
            int type = marker >> 4, info = marker & 0xF;
            return type switch
            {
                0x0 => info switch { 0x8 => false, 0x9 => true, _ => throw new FormatException("unsupported simple value") },
                0x1 => Integer(pos, info),
                0x2 => info switch
                {
                    2 => new PlistReal32(BinaryPrimitives.ReadSingleBigEndian(data.AsSpan(pos + 1, 4))),
                    3 => BinaryPrimitives.ReadDoubleBigEndian(data.AsSpan(pos + 1, 8)),
                    _ => throw new FormatException("bad real size"),
                },
                0x3 => AppleEpoch.AddSeconds(BinaryPrimitives.ReadDoubleBigEndian(data.AsSpan(pos + 1, 8))),
                0x4 => Span(pos, info, 1).ToArray(),
                0x5 => Encoding.ASCII.GetString(Span(pos, info, 1)),
                0x6 => Encoding.BigEndianUnicode.GetString(Span(pos, info, 2)),
                0xA => Array(pos, info, depth),
                0xD => Dict(pos, info, depth),
                _ => throw new FormatException($"unsupported plist type 0x{type:X}"),
            };
        }

        private long Integer(int pos, int info) => (1 << info) switch
        {
            1 => data[pos + 1],
            2 => BinaryPrimitives.ReadUInt16BigEndian(data.AsSpan(pos + 1, 2)),
            4 => BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(pos + 1, 4)),
            8 => BinaryPrimitives.ReadInt64BigEndian(data.AsSpan(pos + 1, 8)),
            16 => BinaryPrimitives.ReadInt64BigEndian(data.AsSpan(pos + 9, 8)), // 128-bit: low 64 bits
            _ => throw new FormatException("bad integer size"),
        };

        private List<object> Array(int pos, int info, int depth)
        {
            var (len, start) = Length(pos, info, refSize);
            var list = new List<object>(len);
            for (var i = 0; i < len; i++) list.Add(Object(Ref(start + i * refSize), depth + 1));
            return list;
        }

        private Dictionary<string, object> Dict(int pos, int info, int depth)
        {
            var (len, start) = Length(pos, info, 2 * refSize);
            var dict = new Dictionary<string, object>(len);
            for (var i = 0; i < len; i++)
            {
                var key = Object(Ref(start + i * refSize), depth + 1) as string ?? throw new FormatException("non-string key");
                dict[key] = Object(Ref(start + (len + i) * refSize), depth + 1);
            }
            return dict;
        }

        private ReadOnlySpan<byte> Span(int pos, int info, int unit)
        {
            var (len, start) = Length(pos, info, unit);
            return data.AsSpan(start, len * unit);
        }

        private int Ref(int pos) => checked((int)ReadUInt(data, pos, refSize));

        /// <summary>Element count and start; checks that <c>count × unit</c> bytes are really there.</summary>
        private (int Length, int Start) Length(int pos, int info, int unit)
        {
            int len, start;
            if (info != 0xF) (len, start) = (info, pos + 1);
            else
            {
                var n = 1 << (data[pos + 1] & 0xF);
                if (n > 8) throw new FormatException("bad length size");
                (len, start) = (checked((int)ReadUInt(data, pos + 2, n)), pos + 2 + n);
            }
            if (len < 0 || (long)len * unit > data.Length - start) throw new FormatException("length past the end");
            return (len, start);
        }
    }

    private static ulong ReadUInt(ReadOnlySpan<byte> data, int pos, int size)
    {
        ulong v = 0;
        for (var i = 0; i < size; i++) v = (v << 8) | data[pos + i];
        return v;
    }

    // MARK: Writing

    public static byte[] Write(object root)
    {
        var count = Count(root);
        var refSize = count < 256 ? 1 : count < 65536 ? 2 : 4;
        var objects = new List<byte[]>(count);
        var top = new Writer(refSize, objects).Add(root);
        using var output = new MemoryStream();
        output.Write("bplist00"u8);
        var offsets = objects.Select(o => { var at = output.Position; output.Write(o); return at; }).ToList();
        WriteOffsetTableAndTrailer(output, offsets, refSize, top);
        return output.ToArray();
    }

    private static void WriteOffsetTableAndTrailer(MemoryStream output, List<long> offsets, int refSize, int top)
    {
        var tableStart = output.Position;
        var offsetSize = tableStart < 256 ? 1 : tableStart < 65536 ? 2 : tableStart < 1L << 32 ? 4 : 8;
        foreach (var o in offsets) WriteUInt(output, (ulong)o, offsetSize);
        Span<byte> trailer = stackalloc byte[32];
        trailer[6] = (byte)offsetSize;
        trailer[7] = (byte)refSize;
        BinaryPrimitives.WriteUInt64BigEndian(trailer[8..], (ulong)offsets.Count);
        BinaryPrimitives.WriteUInt64BigEndian(trailer[16..], (ulong)top);
        BinaryPrimitives.WriteUInt64BigEndian(trailer[24..], (ulong)tableStart);
        output.Write(trailer);
    }

    /// <summary>How many objects <see cref="Writer"/> will write, so the reference size is known first.</summary>
    private static int Count(object value) => 1 + value switch
    {
        Dictionary<string, object> dict => dict.Sum(kv => 1 + Count(kv.Value)),
        List<object> list => list.Sum(Count),
        _ => 0,
    };

    private sealed class Writer(int refSize, List<byte[]> objects)
    {
        public int Add(object value)
        {
            var index = objects.Count;
            objects.Add([]); // placeholder keeps parents before children
            objects[index] = value switch
            {
                Dictionary<string, object> dict => Dict(dict),
                List<object> list => Array(list),
                string s => Str(s),
                bool b => [b ? (byte)0x09 : (byte)0x08],
                PlistReal32 f => Real32(f.Value),
                double d => Real64(d),
                long l => Int(l),
                byte[] bytes => WithLength(0x4, bytes.Length, bytes),
                DateTime t => Date(t),
                _ => throw new ArgumentException($"cannot write {value.GetType()} to a plist"),
            };
            return index;
        }

        private byte[] Dict(Dictionary<string, object> dict)
        {
            var keys = dict.Keys.Select(k => Add(k)).ToList();
            var values = dict.Values.Select(Add).ToList();
            return Container(0xD, dict.Count, keys.Concat(values));
        }

        private byte[] Array(List<object> list) => Container(0xA, list.Count, list.Select(Add).ToList());

        private byte[] Container(int type, int count, IEnumerable<int> refs)
        {
            using var ms = new MemoryStream();
            ms.Write(Header(type, count));
            foreach (var r in refs) WriteUInt(ms, (ulong)r, refSize);
            return ms.ToArray();
        }
    }

    private static byte[] Str(string s)
    {
        if (s.All(c => c < 128)) return WithLength(0x5, s.Length, Encoding.ASCII.GetBytes(s));
        var utf16 = Encoding.BigEndianUnicode.GetBytes(s);
        return WithLength(0x6, utf16.Length / 2, utf16);
    }

    private static byte[] WithLength(int type, int count, byte[] payload) => [.. Header(type, count), .. payload];

    private static byte[] Header(int type, int count)
    {
        if (count < 15) return [(byte)((type << 4) | count)];
        return [(byte)((type << 4) | 0xF), .. Int(count)];
    }

    private static byte[] Int(long v)
    {
        if (v >= 0 && v <= byte.MaxValue) return [0x10, (byte)v];
        if (v >= 0 && v <= ushort.MaxValue) return [0x11, (byte)(v >> 8), (byte)v];
        if (v >= 0 && v <= uint.MaxValue)
        {
            var b = new byte[5]; b[0] = 0x12; BinaryPrimitives.WriteUInt32BigEndian(b.AsSpan(1), (uint)v); return b;
        }
        var e = new byte[9]; e[0] = 0x13; BinaryPrimitives.WriteInt64BigEndian(e.AsSpan(1), v); return e;
    }

    private static byte[] Real32(float f)
    {
        var b = new byte[5]; b[0] = 0x22; BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(1), f); return b;
    }

    private static byte[] Real64(double d)
    {
        var b = new byte[9]; b[0] = 0x23; BinaryPrimitives.WriteDoubleBigEndian(b.AsSpan(1), d); return b;
    }

    private static byte[] Date(DateTime t)
    {
        var b = new byte[9]; b[0] = 0x33;
        BinaryPrimitives.WriteDoubleBigEndian(b.AsSpan(1), (t.ToUniversalTime() - AppleEpoch).TotalSeconds);
        return b;
    }

    private static void WriteUInt(Stream s, ulong v, int size)
    {
        for (var i = size - 1; i >= 0; i--) s.WriteByte((byte)(v >> (i * 8)));
    }
}

/// <summary>A 4-byte real, which is how Swift encodes Float values.</summary>
public readonly record struct PlistReal32(float Value);
