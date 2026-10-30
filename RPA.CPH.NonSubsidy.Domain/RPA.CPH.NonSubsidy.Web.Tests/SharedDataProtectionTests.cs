using System.Net;
using System.Security.Cryptography;
using Azure;
using Azure.Core;
using Azure.Core.Cryptography;
using Azure.Core.Pipeline;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.DataProtection.KeyManagement;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Options;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
public class SharedDataProtectionTests
{
    private const string BlobUri = "https://offlinetest.blob.core.windows.net/keyring/cph.xml";
    private const string KeyUri = "https://offline-test.vault.azure.net/keys/cph-key";

    private static Dictionary<string, string> Settings()
    {
        var settings = RuntimeConfigurationTests.Settings();
        settings["DataProtection:Enabled"] = "true";
        settings["DataProtection:BlobUri"] = BlobUri;
        settings["DataProtection:KeyIdentifier"] = KeyUri;
        settings["DataProtection:ApplicationName"] = "Cph.Offline.Production";
        settings["DataProtection:ManagedIdentityClientId"] = "33333333-3333-3333-3333-333333333333";
        return settings;
    }

    [TestMethod]
    [DataRow("Enabled", "not-a-bool")]
    [DataRow("Enabled", "")]
    [DataRow("BlobUri", "")]
    [DataRow("BlobUri", "   ")]
    [DataRow("BlobUri", "not-a-uri")]
    [DataRow("BlobUri", "http://offlinetest.blob.core.windows.net/keyring/cph.xml")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net/keyring")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net/keyring/")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net/keyring/cph.xml?sig=not-allowed")]
    [DataRow("BlobUri", "https://user@offlinetest.blob.core.windows.net/keyring/cph.xml")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net/keyring/cph.xml#fragment")]
    [DataRow("KeyIdentifier", "")]
    [DataRow("KeyIdentifier", "   ")]
    [DataRow("KeyIdentifier", "not-a-uri")]
    [DataRow("KeyIdentifier", "http://offline-test.vault.azure.net/keys/cph-key")]
    [DataRow("KeyIdentifier", "https://offline-test.vault.azure.net/keys/")]
    [DataRow("KeyIdentifier", "https://offline-test.vault.azure.net/keys/cph-key/version")]
    [DataRow("KeyIdentifier", "https://offline-test.vault.azure.net/secrets/cph-key")]
    [DataRow("KeyIdentifier", "https://offline-test.vault.azure.net/keys/cph-key#fragment")]
    [DataRow("KeyIdentifier", "https://offline-test.vault.azure.net/keys/cph-key?query=value")]
    [DataRow("KeyIdentifier", "https://user@offline-test.vault.azure.net/keys/cph-key")]
    [DataRow("ApplicationName", "")]
    [DataRow("ApplicationName", "   ")]
    [DataRow("ManagedIdentityClientId", "")]
    [DataRow("ManagedIdentityClientId", "   ")]
    [DataRow("ManagedIdentityClientId", "00000000-0000-0000-0000-000000000000")]
    [DataRow("ManagedIdentityClientId", "DefaultAzureCredential")]
    [DataRow("CredentialType", "DefaultAzureCredential")]
    [TestCategory("Unit")]
    public void InvalidOrIncompleteEnablement_FailsDuringApplicationRegistration(string key, string value)
    {
        var settings = Settings();
        settings["DataProtection:" + key] = value;
        Assert.Throws<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(RuntimeConfigurationTests.Configuration(settings)));
    }

    [TestMethod]
    [DataRow("BlobUri")]
    [DataRow("KeyIdentifier")]
    [DataRow("ApplicationName")]
    [DataRow("ManagedIdentityClientId")]
    [TestCategory("Unit")]
    public void MissingRequiredSetting_FailsDuringApplicationRegistration(string key)
    {
        var settings = Settings();
        settings.Remove("DataProtection:" + key);
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(RuntimeConfigurationTests.Configuration(settings)));
    }

    [TestMethod]
    [DataRow("BlobUri", "https://storage.customer.invalid/keyring/cph.xml")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net:8443/keyring/cph.xml")]
    [DataRow("BlobUri", "https://offlinetest.blob.core.windows.net/keyring/cph%20keys.xml")]
    [DataRow("KeyIdentifier", "https://keys.customer.invalid/keys/cph-key")]
    [DataRow("ApplicationName", "CPH Production (customer handover)")]
    [TestCategory("Unit")]
    public void ValidSettings_AreNotRestrictedToHardcodedDomainsOrNameFormats(string key, string value)
    {
        var settings = Settings();
        settings["DataProtection:" + key] = value;
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(RuntimeConfigurationTests.Configuration(settings));
        using var provider = services.BuildServiceProvider();
        Assert.AreEqual(new Uri(settings["DataProtection:BlobUri"]), provider.GetRequiredService<BlobClient>().Uri);
        Assert.AreEqual(settings["DataProtection:ApplicationName"],
            provider.GetRequiredService<IOptions<DataProtectionOptions>>().Value.ApplicationDiscriminator);
        var options = provider.GetRequiredService<IOptions<KeyManagementOptions>>().Value;
        Assert.IsNotNull(options.XmlRepository);
        Assert.IsNotNull(options.XmlEncryptor);
        Assert.IsNotNull(provider.GetRequiredService<ManagedIdentityCredential>());
        Assert.IsNull(provider.GetService<DefaultAzureCredential>());
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void ApplicationName_LongerThan128Characters_IsPreserved()
    {
        var settings = Settings();
        var applicationName = new string('a', 129);
        settings["DataProtection:ApplicationName"] = applicationName;
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(RuntimeConfigurationTests.Configuration(settings));
        using var provider = services.BuildServiceProvider();
        Assert.AreEqual(applicationName,
            provider.GetRequiredService<IOptions<DataProtectionOptions>>().Value.ApplicationDiscriminator);
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void MissingEnablementFlag_DoesNotSilentlyUseLocalKeys()
    {
        var settings = Settings();
        settings.Remove("DataProtection:Enabled");
        Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(RuntimeConfigurationTests.Configuration(settings)));
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    [TestCategory("Unit")]
    public void DisabledOrAbsentConfiguration_PreservesLocalProvider(bool explicitDisable)
    {
        var settings = RuntimeConfigurationTests.Settings();
        if (explicitDisable) settings["DataProtection:Enabled"] = "false";
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(RuntimeConfigurationTests.Configuration(settings));
        using var provider = services.BuildServiceProvider();
        Assert.IsNull(provider.GetService<ManagedIdentityCredential>());
        Assert.IsNull(provider.GetRequiredService<IOptions<KeyManagementOptions>>().Value.XmlRepository);
        Assert.IsNull(provider.GetRequiredService<IOptions<KeyManagementOptions>>().Value.XmlEncryptor);
    }

    [TestMethod]
    [TestCategory("Integration")]
    public void EnabledApplication_RegistersRealAzureRepositoryEncryptorAndOnlyManagedIdentity()
    {
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(RuntimeConfigurationTests.Configuration(Settings()));
        using var provider = services.BuildServiceProvider();
        Assert.IsNotNull(provider.GetRequiredService<ManagedIdentityCredential>());
        Assert.IsNull(provider.GetService<DefaultAzureCredential>());
        Assert.AreEqual(new Uri(BlobUri), provider.GetRequiredService<BlobClient>().Uri);
        var options = provider.GetRequiredService<IOptions<KeyManagementOptions>>().Value;
        Assert.IsNotNull(options.XmlRepository);
        Assert.IsNotNull(options.XmlEncryptor);
        Assert.AreEqual("Cph.Offline.Production",
            provider.GetRequiredService<IOptions<DataProtectionOptions>>().Value.ApplicationDiscriminator);
    }

    [TestMethod]
    [DataRow("Cph.Offline.Production")]
    [DataRow("CPH Production (customer handover)")]
    [TestCategory("Integration")]
    public void RealProvider_PersistsEncryptedKeysAndSharesAcrossReplicasButNotApplicationNames(string applicationName)
    {
        using var blob = new OfflineBlob();
        using var keys = new OfflineKeyResolver();
        using var first = Provider(blob, keys, applicationName);
        var encrypted = first.GetRequiredService<IDataProtectionProvider>().CreateProtector("cookie-test").Protect("offline payload");
        Assert.IsTrue(blob.Requests > 0);
        var xml = System.Text.Encoding.UTF8.GetString(blob.Bytes);
        StringAssert.Contains(xml, "encryptedSecret");
        StringAssert.Contains(xml, KeyUri + "/offline-version");
        Assert.IsFalse(xml.Contains("<masterKey", StringComparison.Ordinal));
        using var second = Provider(blob, keys, applicationName);
        Assert.AreEqual("offline payload",
            second.GetRequiredService<IDataProtectionProvider>().CreateProtector("cookie-test").Unprotect(encrypted));
        using var otherEnvironment = Provider(blob, keys, "Cph.Offline.UAT");
        Assert.ThrowsExactly<CryptographicException>(() =>
            otherEnvironment.GetRequiredService<IDataProtectionProvider>().CreateProtector("cookie-test").Unprotect(encrypted));
        Assert.IsTrue(keys.Wraps > 0);
        Assert.IsTrue(keys.Unwraps > 0);
    }

    [TestMethod]
    [TestCategory("Integration")]
    public void BlobAccessFailure_PropagatesWithoutEphemeralFallback()
    {
        using var blob = new OfflineBlob { Deny = true };
        using var keys = new OfflineKeyResolver();
        using var provider = Provider(blob, keys);
        Assert.ThrowsExactly<RequestFailedException>(() =>
            provider.GetRequiredService<IOptions<KeyManagementOptions>>().Value.XmlRepository.GetAllElements());
        Assert.ThrowsExactly<CryptographicException>(() =>
            provider.GetRequiredService<IDataProtectionProvider>().CreateProtector("cookie-test").Protect("must not succeed"));
        Assert.IsNull(blob.Bytes);
    }

    [TestMethod]
    [TestCategory("Integration")]
    public void KeyWrapFailure_DoesNotPersistAnUnencryptedKey()
    {
        using var blob = new OfflineBlob();
        using var keys = new OfflineKeyResolver { Deny = true };
        using var provider = Provider(blob, keys);
        Assert.ThrowsExactly<RequestFailedException>(() =>
            provider.GetRequiredService<IKeyManager>().CreateNewKey(DateTimeOffset.UtcNow, DateTimeOffset.UtcNow.AddDays(90)));
        Assert.IsNull(blob.Bytes);
    }

    private static ServiceProvider Provider(OfflineBlob blob, OfflineKeyResolver keys, string appName = null)
    {
        var settings = Settings();
        if (appName != null) settings["DataProtection:ApplicationName"] = appName;
        var services = new ServiceCollection();
        services.AddLogging();
        services.AddCphApplication(RuntimeConfigurationTests.Configuration(settings));
        services.Replace(ServiceDescriptor.Singleton(new BlobClient(new Uri(BlobUri), new OfflineCredential(),
            new BlobClientOptions { Transport = new HttpClientTransport(new HttpClient(blob)), Retry = { MaxRetries = 0 } })));
        services.Replace(ServiceDescriptor.Singleton<IKeyEncryptionKeyResolver>(keys));
        return services.BuildServiceProvider();
    }

    private sealed class OfflineCredential : TokenCredential
    {
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            new("offline-token", DateTimeOffset.UtcNow.AddHours(1));
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken) =>
            ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class OfflineBlob : HttpMessageHandler
    {
        public byte[] Bytes { get; private set; }
        public bool Deny { get; init; }
        public int Requests { get; private set; }

        protected override HttpResponseMessage Send(HttpRequestMessage request, CancellationToken cancellationToken) =>
            SendAsync(request, cancellationToken).GetAwaiter().GetResult();

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            Assert.AreEqual("offlinetest.blob.core.windows.net", request.RequestUri.Host);
            if (Deny) return Error(HttpStatusCode.Forbidden, "AuthorizationFailure");
            if (request.Method == HttpMethod.Put)
            {
                Bytes = await request.Content.ReadAsByteArrayAsync(cancellationToken);
                var created = new HttpResponseMessage(HttpStatusCode.Created);
                created.Headers.ETag = new System.Net.Http.Headers.EntityTagHeaderValue("\"offline-etag\"");
                return created;
            }
            Assert.AreEqual(HttpMethod.Get, request.Method);
            if (Bytes == null) return Error(HttpStatusCode.NotFound, "BlobNotFound");
            var response = new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(Bytes) };
            response.Headers.ETag = new System.Net.Http.Headers.EntityTagHeaderValue("\"offline-etag\"");
            return response;
        }

        private static HttpResponseMessage Error(HttpStatusCode status, string code)
        {
            var response = new HttpResponseMessage(status)
            {
                Content = new StringContent($"<Error><Code>{code}</Code><Message>Offline test</Message></Error>")
            };
            response.Headers.Add("x-ms-error-code", code);
            return response;
        }
    }

    private sealed class OfflineKeyResolver : IKeyEncryptionKeyResolver, IKeyEncryptionKey, IDisposable
    {
        private readonly RSA rsa = RSA.Create(2048);
        public bool Deny { get; init; }
        public int Wraps { get; private set; }
        public int Unwraps { get; private set; }
        public string KeyId => KeyUri + "/offline-version";
        public IKeyEncryptionKey Resolve(string keyId, CancellationToken cancellationToken = default)
        {
            Assert.IsTrue(keyId == KeyUri || keyId == KeyId);
            if (Deny) throw new RequestFailedException(403, "Offline key denied");
            return this;
        }
        public Task<IKeyEncryptionKey> ResolveAsync(string keyId, CancellationToken cancellationToken = default) =>
            Task.FromResult(Resolve(keyId, cancellationToken));
        public byte[] WrapKey(string algorithm, ReadOnlyMemory<byte> key, CancellationToken cancellationToken = default)
        {
            Assert.AreEqual("RSA-OAEP", algorithm);
            Wraps++;
            return rsa.Encrypt(key.Span, RSAEncryptionPadding.OaepSHA1);
        }
        public Task<byte[]> WrapKeyAsync(string algorithm, ReadOnlyMemory<byte> key, CancellationToken cancellationToken = default) =>
            Task.FromResult(WrapKey(algorithm, key, cancellationToken));
        public byte[] UnwrapKey(string algorithm, ReadOnlyMemory<byte> encryptedKey, CancellationToken cancellationToken = default)
        {
            Assert.AreEqual("RSA-OAEP", algorithm);
            Unwraps++;
            return rsa.Decrypt(encryptedKey.Span, RSAEncryptionPadding.OaepSHA1);
        }
        public Task<byte[]> UnwrapKeyAsync(string algorithm, ReadOnlyMemory<byte> encryptedKey, CancellationToken cancellationToken = default) =>
            Task.FromResult(UnwrapKey(algorithm, encryptedKey, cancellationToken));
        public void Dispose() => rsa.Dispose();
    }
}
