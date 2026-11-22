using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using Glasspen.Core.Protocol;
using Glasspen.Windows.App;

namespace Glasspen.Windows.Remote;

/// <summary>
/// JPEG stills of the primary display for the phone. Uses GDI without CAPTUREBLT, which leaves out
/// layered windows (the overlay and toolbar), so the phone gets the screen without the drawings and draws
/// those itself as sharp vectors.
/// </summary>
public static class ScreenCapture
{
    private static readonly ImageCodecInfo Jpeg = ImageCodecInfo.GetImageEncoders().First(c => c.FormatID == ImageFormat.Jpeg.Guid);

    /// <summary>
    /// Captures <paramref name="rect"/> (normalized; clamped to the primary display) scaled to fit within
    /// <paramref name="maxWidth"/>×<paramref name="maxHeight"/> pixels. Null when there is nothing to capture.
    /// </summary>
    public static byte[]? Capture(NormRect rect, int maxWidth, int maxHeight, long quality = 70)
    {
        var screen = System.Windows.Forms.Screen.PrimaryScreen?.Bounds ?? Rectangle.Empty;
        if (screen.Width <= 0 || screen.Height <= 0 || rect.ClampedToDisplay() is not { } r) return null;
        var src = Rectangle.Intersect(screen, new Rectangle(
            screen.Left + (int)(r.X * screen.Width), screen.Top + (int)(r.Y * screen.Height),
            Math.Max(1, (int)(r.W * screen.Width)), Math.Max(1, (int)(r.H * screen.Height))));
        if (src.Width <= 0 || src.Height <= 0) return null;
        var scale = Math.Min(1.0, Math.Min((double)maxWidth / src.Width, (double)maxHeight / src.Height));
        var size = new Size(Math.Max(1, (int)(src.Width * scale)), Math.Max(1, (int)(src.Height * scale)));
        using var image = Grab(src, size);
        if (image is null) return null;
        using var stream = new MemoryStream();
        using var parameters = new EncoderParameters(1);
        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, quality);
        image.Save(stream, Jpeg, parameters);
        return stream.ToArray();
    }

    /// <summary>Copies <paramref name="src"/> of the screen, scaled to <paramref name="size"/> in the same GDI call.</summary>
    private static Bitmap? Grab(Rectangle src, Size size)
    {
        var screenDc = Native.GetDC(IntPtr.Zero);
        var memDc = Native.CreateCompatibleDC(screenDc);
        var bitmap = Native.CreateCompatibleBitmap(screenDc, size.Width, size.Height);
        var old = Native.SelectObject(memDc, bitmap);
        bool copied;
        try
        {
            if (size == src.Size)
            {
                copied = Native.BitBlt(memDc, 0, 0, size.Width, size.Height, screenDc, src.X, src.Y, Native.SRCCOPY);
            }
            else
            {
                Native.SetStretchBltMode(memDc, Native.HALFTONE);
                Native.SetBrushOrgEx(memDc, 0, 0, IntPtr.Zero);
                copied = Native.StretchBlt(memDc, 0, 0, size.Width, size.Height, screenDc, src.X, src.Y, src.Width, src.Height, Native.SRCCOPY);
            }
        }
        finally
        {
            // Deselect before deleting: a bitmap still selected into a DC can't be deleted and would leak.
            Native.SelectObject(memDc, old);
            Native.DeleteDC(memDc);
            Native.ReleaseDC(IntPtr.Zero, screenDc);
        }
        try
        {
            return copied ? Image.FromHbitmap(bitmap) : null;
        }
        finally
        {
            Native.DeleteObject(bitmap);
        }
    }
}
