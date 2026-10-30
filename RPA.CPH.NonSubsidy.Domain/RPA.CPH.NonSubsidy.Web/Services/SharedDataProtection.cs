using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.DataProtection;

namespace RPA.CPH.NonSubsidy.Web.Services;

public sealed class SharedDataProtectionOptions
{
    public bool Enabled { get; set; }
    public string BlobUri { get; set; }
    public string KeyIdentifier { get; set; }
    public string ApplicationName { get; set; }
    public string ManagedIdentityClientId { get; set; }
}

public static class SharedDataProtection
{
    public static IServiceCollection AddCphDataProtection(this IServiceCollection services, IConfiguration configuration)
    {
        var section = configuration.GetSection("DataProtection");
        var settings = section.Get<SharedDataProtectionOptions>(options => options.ErrorOnUnknownConfiguration = true) ?? new();

        if (section.Exists() && !bool.TryParse(section["Enabled"], out _))
            throw new InvalidOperationException("DataProtection:Enabled must explicitly be true or false.");

        services.Configure<SharedDataProtectionOptions>(section);
        
        if (!settings.Enabled) return services;

        var blob = Endpoint(settings.BlobUri, "BlobUri");
        if (blob.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Length < 2 ||
            blob.AbsolutePath.EndsWith('/'))
            throw Invalid("BlobUri", "must identify a container/blob");

        var key = Endpoint(settings.KeyIdentifier, "KeyIdentifier");

        // A versionless URI lets newly generated Data Protection keys use the current wrapping-key version.
        var segments = key.AbsolutePath.Split('/');
        if (segments.Length != 3 || segments[1] != "keys" || string.IsNullOrEmpty(segments[2]))
            throw Invalid("KeyIdentifier", "must be a versionless /keys/<key-name> identifier");
        if (string.IsNullOrWhiteSpace(settings.ApplicationName))
            throw Invalid("ApplicationName", "must be a stable environment-specific name");
        if (!Guid.TryParse(settings.ManagedIdentityClientId, out var clientId) || clientId == Guid.Empty)
            throw Invalid("ManagedIdentityClientId", "must identify the user-assigned managed identity");

        // Use only the selected ACA identity, never a developer credential or a stored secret.
        services.AddSingleton(new ManagedIdentityCredential(ManagedIdentityId.FromUserAssignedClientId(clientId.ToString())));
        services.AddSingleton(provider => new BlobClient(blob, provider.GetRequiredService<ManagedIdentityCredential>()));
        // Share keys across replicas and replacements, and encrypt the stored key ring with Key Vault.
        // ApplicationName must remain identical within an environment and distinct between environments.
        services.AddDataProtection()
            .SetApplicationName(settings.ApplicationName)
            .PersistKeysToAzureBlobStorage(provider => provider.GetRequiredService<BlobClient>())
            .ProtectKeysWithAzureKeyVault(key, provider => provider.GetRequiredService<ManagedIdentityCredential>());
        
        return services;
    }

    private static Uri Endpoint(string value, string setting)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps ||
            !string.IsNullOrEmpty(uri.UserInfo) || !string.IsNullOrEmpty(uri.Query) ||
            !string.IsNullOrEmpty(uri.Fragment))
            throw Invalid(setting, "must be an HTTPS resource identifier without credentials, query or fragment");
        
        return uri;
    }

    private static InvalidOperationException Invalid(string name, string rule) =>
        new($"DataProtection:{name} {rule}.");
}
