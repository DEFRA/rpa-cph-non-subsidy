using Microsoft.AspNetCore.Builder;
using Microsoft.EntityFrameworkCore;
using Microsoft.Extensions.DependencyInjection;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Web.Services;

namespace RPA.CPH.NonSubsidy.Web.Tests;

[TestClass]
[TestCategory("Unit")]
public class LocalSqlConfigurationTests
{
    [TestMethod]
    [DataRow("Development", @"Server=(localdb)\MSSQLLocalDB;Database=DeveloperDatabase;Integrated Security=True;Encrypt=True;TrustServerCertificate=True")]
    [DataRow("Development", "Server=sql-dev.invalid;Database=DeveloperDatabase;User ID=developer;Password=offline-test-only;Encrypt=Mandatory;TrustServerCertificate=False")]
    [DataRow("Production", "Server=sql.invalid;Database=Test;Authentication=Active Directory Managed Identity;Encrypt=Mandatory;TrustServerCertificate=False")]
    [DataRow("Production", "Server=sql.invalid;Authentication=Active Directory Managed Identity;Encrypt=Optional;TrustServerCertificate=True;Persist Security Info=True")]
    [DataRow("Production", "Database=Test;Authentication=Active Directory Managed Identity;Encrypt=Mandatory;TrustServerCertificate=False")]
    public void SqlRegistration_PreservesSuppliedSettingsAndProviderDefaultsWithoutOpeningConnection(string environment, string connection)
    {
        var settings = RuntimeConfigurationTests.Settings();
        settings["ConnectionStrings:CPHContext"] = connection;
        var builder = WebApplication.CreateBuilder(new WebApplicationOptions { EnvironmentName = environment });
        builder.Services.AddCphApplication(RuntimeConfigurationTests.Configuration(settings), builder.Environment);
        using var provider = builder.Services.BuildServiceProvider();
        using var scope = provider.CreateScope();
        var context = scope.ServiceProvider.GetRequiredService<CPHContext>();
        using var expected = new CPHContext(new DbContextOptionsBuilder<CPHContext>().UseSqlServer(connection).Options);
        Assert.AreEqual(expected.Database.GetConnectionString(), context.Database.GetConnectionString());
        Assert.AreEqual(System.Data.ConnectionState.Closed, context.Database.GetDbConnection().State);

        int[] ids = [105000001, 105000002];
        Assert.AreEqual(
            expected.Customers.Where(x => ids.Contains(x.SBI)).ToQueryString(),
            context.Customers.Where(x => ids.Contains(x.SBI)).ToQueryString(),
            "Registration must not introduce a machine-specific SQL compatibility override.");
    }

    [TestMethod]
    [DataRow(" ")]
    [DataRow("Server=private-server.invalid;Database=Test;UnsupportedKey=private-value")]
    public void InvalidOrBlankConnectionString_FailsAtRegistrationWithoutExposingValues(string connection)
    {
        var settings = RuntimeConfigurationTests.Settings();
        settings["ConnectionStrings:CPHContext"] = connection;
        var error = Assert.ThrowsExactly<InvalidOperationException>(() =>
            new ServiceCollection().AddCphApplication(RuntimeConfigurationTests.Configuration(settings)));
        StringAssert.Contains(error.Message, "ConnectionStrings:CPHContext");
        Assert.IsFalse(error.ToString().Contains("private-", StringComparison.Ordinal));
    }
}
