using System.Globalization;
using System.Text;
using System.Xml;
namespace YtdlpStudio.Core;

/// Apple property lists, as spoken by usbmuxd, lockdownd and the iPhone's Ringtones.plist.
/// Values map to: string, long, double, bool, byte[], DateTime, List&lt;object&gt; and Dictionary&lt;string, object&gt;.
/// Writes XML; reads XML and binary ("bplist00").
public static class Plist {
    public static byte[] ToXml(object root) {
        var builder = new StringBuilder();
        builder.Append("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n");
        Write(builder, root, 0);
        builder.Append("</plist>\n");
        return Encoding.UTF8.GetBytes(builder.ToString());
    }

    static void Write(StringBuilder b, object value, int depth) {
        string indent = new('\t', depth);
        switch (value) {
            case string s: b.Append(indent).Append("<string>").Append(Escape(s)).Append("</string>\n"); break;
            case bool v: b.Append(indent).Append(v ? "<true/>\n" : "<false/>\n"); break;
            case byte[] data: b.Append(indent).Append("<data>").Append(Convert.ToBase64String(data)).Append("</data>\n"); break;
            case DateTime date: b.Append(indent).Append("<date>").Append(date.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture)).Append("</date>\n"); break;
            case double or float: b.Append(indent).Append("<real>").Append(Convert.ToDouble(value, CultureInfo.InvariantCulture).ToString("R", CultureInfo.InvariantCulture)).Append("</real>\n"); break;
            case sbyte or byte or short or ushort or int or uint or long or ulong:
                b.Append(indent).Append("<integer>").Append(Convert.ToString(value, CultureInfo.InvariantCulture)).Append("</integer>\n"); break;
            case IDictionary<string, object> dict:
                b.Append(indent).Append("<dict>\n");
                foreach (var (key, item) in dict) { b.Append(indent).Append("\t<key>").Append(Escape(key)).Append("</key>\n"); Write(b, item, depth + 1); }
                b.Append(indent).Append("</dict>\n"); break;
            case System.Collections.IEnumerable list:
                b.Append(indent).Append("<array>\n");
                foreach (var item in list) Write(b, item!, depth + 1);
                b.Append(indent).Append("</array>\n"); break;
            default: throw new ArgumentException("Cannot store " + value?.GetType().Name + " in a property list.");
        }
    }
    static string Escape(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;");

    public static object Parse(byte[] data) {
        if (data.Length >= 8 && Encoding.ASCII.GetString(data, 0, 8) == "bplist00") return new BinaryReader(data).Read();
        var doc = new XmlDocument { XmlResolver = null };
        using (var reader = XmlReader.Create(new MemoryStream(data), new XmlReaderSettings { DtdProcessing = DtdProcessing.Ignore, XmlResolver = null })) doc.Load(reader);
        var root = doc.DocumentElement ?? throw new FormatException("Empty property list.");
        if (root.Name == "plist") root = root.ChildNodes.OfType<XmlElement>().FirstOrDefault() ?? throw new FormatException("Empty property list.");
        return ReadXml(root);
    }
    public static Dictionary<string, object> ParseDict(byte[] data) =>
        Parse(data) as Dictionary<string, object> ?? throw new FormatException("The property list is not a dictionary.");

    static object ReadXml(XmlElement e) => e.Name switch {
        "string" => e.InnerText,
        "integer" => long.TryParse(e.InnerText.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out var n) ? n : (object)(long)ulong.Parse(e.InnerText.Trim(), CultureInfo.InvariantCulture),
        "real" => double.Parse(e.InnerText.Trim(), CultureInfo.InvariantCulture),
        "true" => true, "false" => false,
        "data" => Convert.FromBase64String(string.Concat(e.InnerText.Where(c => !char.IsWhiteSpace(c)))),
        "date" => DateTime.Parse(e.InnerText.Trim(), CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal),
        "array" => e.ChildNodes.OfType<XmlElement>().Select(ReadXml).ToList(),
        "dict" => ReadDict(e),
        _ => throw new FormatException("Unknown property list element <" + e.Name + ">.")
    };
    static Dictionary<string, object> ReadDict(XmlElement e) {
        var dict = new Dictionary<string, object>(); string? key = null;
        foreach (var child in e.ChildNodes.OfType<XmlElement>()) {
            if (child.Name == "key") key = child.InnerText;
            else if (key != null) { dict[key] = ReadXml(child); key = null; }
        }
        return dict;
    }

    /// Reads Apple's binary property list format (version 00).
    sealed class BinaryReader(byte[] d) {
        int offsetSize, refSize; long[] offsets = [];
        public object Read() {
            int t = d.Length - 32;
            offsetSize = d[t + 6]; refSize = d[t + 7];
            long count = (long)Uint(t + 8, 8), top = (long)Uint(t + 16, 8), table = (long)Uint(t + 24, 8);
            if (count <= 0 || count > d.Length || table + count * offsetSize > t) throw new FormatException("Damaged binary property list.");
            offsets = new long[count];
            for (long i = 0; i < count; i++) offsets[i] = (long)Uint((int)(table + i * offsetSize), offsetSize);
            return Object(top, 0);
        }
        ulong Uint(int at, int size) { ulong v = 0; for (int i = 0; i < size; i++) v = (v << 8) | d[at + i]; return v; }
        (long Length, int Start) Count(int at, int low) {
            if (low != 0xF) return (low, at + 1);
            int marker = d[at + 1]; int size = 1 << (marker & 0xF);
            return ((long)Uint(at + 2, size), at + 2 + size);
        }
        object Object(long index, int depth) {
            if (depth > 64 || index < 0 || index >= offsets.Length) throw new FormatException("Damaged binary property list.");
            int at = (int)offsets[index]; int marker = d[at], high = marker >> 4, low = marker & 0xF;
            switch (high) {
                case 0x0: return low switch { 0x8 => false, 0x9 => true, _ => "" };
                case 0x1: {
                    int size = 1 << low; ulong v = Uint(at + 1, size);
                    return size == 8 ? unchecked((long)v) : size == 16 ? unchecked((long)Uint(at + 9, 8)) : (long)v;
                }
                case 0x2: {
                    int size = 1 << low; var bytes = d[(at + 1)..(at + 1 + size)]; Array.Reverse(bytes);
                    return size == 4 ? BitConverter.ToSingle(bytes) : BitConverter.ToDouble(bytes);
                }
                case 0x3: { var bytes = d[(at + 1)..(at + 9)]; Array.Reverse(bytes); return new DateTime(2001, 1, 1, 0, 0, 0, DateTimeKind.Utc).AddSeconds(BitConverter.ToDouble(bytes)); }
                case 0x4: { var (n, s) = Count(at, low); return d[s..(s + (int)n)]; }
                case 0x5: { var (n, s) = Count(at, low); return Encoding.ASCII.GetString(d, s, (int)n); }
                case 0x6: { var (n, s) = Count(at, low); return Encoding.BigEndianUnicode.GetString(d, s, (int)n * 2); }
                case 0x8: { int size = low + 1; return (long)Uint(at + 1, size); }
                case 0xA: {
                    var (n, s) = Count(at, low); var list = new List<object>((int)n);
                    for (int i = 0; i < n; i++) list.Add(Object((long)Uint(s + i * refSize, refSize), depth + 1));
                    return list;
                }
                case 0xD: {
                    var (n, s) = Count(at, low); var dict = new Dictionary<string, object>((int)n);
                    for (int i = 0; i < n; i++) {
                        var key = Object((long)Uint(s + i * refSize, refSize), depth + 1) as string ?? throw new FormatException("Property list key is not a string.");
                        dict[key] = Object((long)Uint(s + (int)(n + i) * refSize, refSize), depth + 1);
                    }
                    return dict;
                }
                default: throw new FormatException($"Unsupported binary property list object 0x{marker:X2}.");
            }
        }
    }
}
