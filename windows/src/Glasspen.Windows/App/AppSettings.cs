using System;
using System.IO;
using System.Text.Json;

namespace Glasspen.Windows.App;

public enum ToolbarPosition { Bottom, Left, Right }

/// <summary>User preferences, saved as JSON in %AppData%\Glasspen Meet\settings.json.</summary>
public sealed class AppSettings
{
    public double BoardOpacity { get; set; } = 0.9;
    public double InkOpacity { get; set; } = 1.0;
    /// <summary>Seconds before strokes fade; 0 keeps them until cleared.</summary>
    public double FadeDelaySeconds { get; set; } = 1.0;
    public double ToolbarOpacity { get; set; } = 1.0;
    public ToolbarPosition ToolbarPosition { get; set; } = ToolbarPosition.Bottom;
    /// <summary>Ctrl+Alt+Shift+1…0 pick a tool from any app.</summary>
    public bool ToolHotKeysEnabled { get; set; } = true;

    /// <summary>Buy Me a Coffee page; empty hides every coffee link.</summary>
    public const string BuyMeACoffeeUrl = "https://buymeacoffee.com/toncatalan";

    private static readonly string FilePath =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Glasspen Meet", "settings.json");

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath)) return JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? new AppSettings();
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException)
        {
            // A broken settings file falls back to the defaults.
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Not being able to save preferences must not stop the app.
        }
    }
}
