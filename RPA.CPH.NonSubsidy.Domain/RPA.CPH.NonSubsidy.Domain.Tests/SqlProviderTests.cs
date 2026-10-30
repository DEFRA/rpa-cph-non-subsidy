using System.Data;
using System.Text.RegularExpressions;
using Microsoft.Data.SqlClient;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Metadata;
using NUnit.Framework;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Repository;

namespace RPA.CPH.NonSubsidy.Domain.Tests;

[TestFixture]
[Category("Integration")]
public class SqlProviderTests
{
    private static CPHContext CreateContext() => new(new DbContextOptionsBuilder<CPHContext>()
        .UseSqlServer("Server=unused.invalid;Database=OfflineTests;Authentication=Active Directory Managed Identity;Encrypt=Mandatory;TrustServerCertificate=False")
        .Options);

    [Test]
    public void Context_UsesModernProviderWithoutOpeningConnection()
    {
        using var context = CreateContext();
        var dbConnection = context.Database.GetDbConnection();
        Assert.That(context.Database.ProviderName, Is.EqualTo("Microsoft.EntityFrameworkCore.SqlServer"));
        Assert.That(dbConnection, Is.TypeOf<SqlConnection>());
        Assert.That(dbConnection.State, Is.EqualTo(ConnectionState.Closed));
        var connection = new SqlConnectionStringBuilder(dbConnection.ConnectionString);
        Assert.That(connection.Authentication, Is.EqualTo(SqlAuthenticationMethod.ActiveDirectoryManagedIdentity));
        Assert.That(connection.Encrypt, Is.EqualTo(SqlConnectionEncryptOption.Mandatory));
        Assert.That(connection.TrustServerCertificate, Is.False);
        Assert.That(context.Model.GetEntityTypes().Count(), Is.EqualTo(6));
        Assert.That(dbConnection.State, Is.EqualTo(ConnectionState.Closed));
    }

    [Test]
    public void SqlServerModel_PreservesEveryHistoricalTableColumnTypeNullabilityAndKey()
    {
        using var context = CreateContext();
        AssertEntity<Customer>("CPH", "Customers", "CustomerId", true,
            ("CustomerId", "int", false), ("SBI", "int", false), ("BusinessName", "nvarchar(max)", false));
        AssertEntity<Address>("CPH", "Addresses", "AddressId", true,
            ("AddressId", "int", false), ("CustomerId", "int", false),
            ("Address1", "nvarchar(max)", false), ("Address2", "nvarchar(max)", true),
            ("Address3", "nvarchar(max)", true), ("Address4", "nvarchar(max)", true),
            ("Address5", "nvarchar(max)", true), ("PostCode", "nvarchar(max)", false));
        AssertEntity<Land>("CPH", "Land", "LandId", true,
            ("LandId", "int", false), ("CustomerId", "int", false),
            ("County", "int", false), ("Parish", "int", false), ("Holding", "int", false));
        AssertEntity<LandParcel>("CPH", "LandParcels", "LandParcelId", true,
            ("LandParcelId", "int", false), ("LandId", "int", false),
            ("GridReference", "nvarchar(max)", true), ("PlaceOfBusiness", "bit", false), ("Active", "bit", false));
        AssertEntity<Case>("CPH", "Cases", "CustomerId", false,
            ("CustomerId", "int", false), ("CRMCaseReferenceNumber", "nvarchar(max)", false));
        AssertEntity<Audit>("Audit", "Audit", "CustomerId", false,
            ("CustomerId", "int", false), ("LastUpdatedBy", "nvarchar(max)", true), ("LastUpdated", "datetime", false));
        Assert.That(context.Model.FindEntityType(typeof(Customer)).GetIndexes(), Is.Empty,
            "The historical unique SBI index was removed; it must not return.");
        var active = context.Model.FindEntityType(typeof(LandParcel)).FindProperty("Active");
        Assert.That(active.GetDefaultValue(), Is.EqualTo(false));
        Assert.That(active.ValueGenerated, Is.EqualTo(ValueGenerated.Never),
            "Both explicit false and constructor-default true must be sent to SQL.");
        Assert.That(new LandParcel().Active, Is.True, "Retain the application's constructor default.");
        Assert.That(context.Model.GetEntityTypes().SelectMany(x => x.GetIndexes()).Count(), Is.EqualTo(5));
        foreach (var entity in context.Model.GetEntityTypes())
        {
            Assert.That(entity.FindPrimaryKey().GetName(), Is.EqualTo($"PK_{entity.GetSchema()}.{entity.GetTableName()}"));
            foreach (var index in entity.GetIndexes())
                Assert.That(index.GetDatabaseName(), Is.EqualTo("IX_" + index.Properties.Single().Name));
            foreach (var foreignKey in entity.GetForeignKeys())
                Assert.That(foreignKey.GetConstraintName(), Is.EqualTo(
                    $"FK_{entity.GetSchema()}.{entity.GetTableName()}_{foreignKey.PrincipalEntityType.GetSchema()}.{foreignKey.PrincipalEntityType.GetTableName()}_{foreignKey.Properties.Single().Name}"));
        }

        void AssertEntity<T>(string schema, string table, string key, bool generated,
            params (string Name, string StoreType, bool Nullable)[] columns)
        {
            var entity = context.Model.FindEntityType(typeof(T));
            Assert.That(entity.GetSchema(), Is.EqualTo(schema));
            Assert.That(entity.GetTableName(), Is.EqualTo(table));
            Assert.That(entity.FindPrimaryKey().Properties.Select(x => x.Name), Is.EqualTo(new[] { key }));
            Assert.That(entity.FindProperty(key).ValueGenerated,
                Is.EqualTo(generated ? ValueGenerated.OnAdd : ValueGenerated.Never));
            Assert.That(entity.GetProperties().Select(x => x.Name),
                Is.EquivalentTo(columns.Select(x => x.Name)), "No computed/shadow columns may be introduced.");
            var store = StoreObjectIdentifier.Table(table, schema);
            foreach (var column in columns)
            {
                var property = entity.FindProperty(column.Name);
                Assert.That(property.GetColumnName(store), Is.EqualTo(column.Name));
                Assert.That(property.GetRelationalTypeMapping().StoreType, Is.EqualTo(column.StoreType));
                Assert.That(property.IsNullable, Is.EqualTo(column.Nullable));
                Assert.That(property.GetMaxLength(), Is.Null, "EF6 imposed no maximum length.");
            }
        }
    }

    [Test]
    public void SqlServerModel_PreservesRequiredSharedKeysAndAllFiveCascadeForeignKeys()
    {
        using var context = CreateContext();
        Assert.That(context.Model.GetEntityTypes().SelectMany(x => x.GetForeignKeys()).Count(), Is.EqualTo(5));
        Check<Address, Customer>("CustomerId", false);
        Check<Land, Customer>("CustomerId", false);
        Check<LandParcel, Land>("LandId", false);
        Check<Case, Customer>("CustomerId", true);
        Check<Audit, Customer>("CustomerId", true);

        void Check<TDependent, TPrincipal>(string key, bool sharedKey)
        {
            var entity = context.Model.FindEntityType(typeof(TDependent));
            var fk = entity.GetForeignKeys().Single();
            Assert.That(fk.PrincipalEntityType.ClrType, Is.EqualTo(typeof(TPrincipal)));
            Assert.That(fk.Properties.Select(x => x.Name), Is.EqualTo(new[] { key }));
            Assert.That(fk.PrincipalKey, Is.SameAs(fk.PrincipalEntityType.FindPrimaryKey()));
            Assert.That(fk.DeleteBehavior, Is.EqualTo(DeleteBehavior.Cascade));
            Assert.That(fk.IsRequired, Is.True);
            Assert.That(fk.IsUnique, Is.EqualTo(sharedKey));
            if (sharedKey)
            {
                Assert.That(fk.IsRequiredDependent, Is.True);
                Assert.That(fk.Properties, Is.EqualTo(entity.FindPrimaryKey().Properties));
            }
        }
    }

    [Test]
    public void SqlServerQueries_TranslateExactSbiSearchAndActiveParcelGraphWithoutConnection()
    {
        using var context = CreateContext();
        var search = "105000001";
        var customers = (IQueryable<Customer>)new SQLRepository<Customer>(context)
            .FindBy(x => x.SBI.ToString() == search.Trim());
        var sql = customers.OrderByDescending(x => x.Audit.LastUpdated).ThenBy(x => x.SBI).ToQueryString();
        Assert.That(sql, Does.Contain("[CPH].[Customers]").And.Contain("[CPH].[Cases]")
            .And.Contain("[Audit].[Audit]").And.Contain("ORDER BY").And.Contain("[LastUpdated] DESC"));
        Assert.That(sql, Does.Contain("CONVERT(varchar(11),").And.Contain("[SBI])"));
        var parcels = (IQueryable<LandParcel>)new SQLRepository<LandParcel>(context).FindBy(x => x.Active);
        var parcelSql = parcels.OrderBy(x => x.Land.Customer.SBI).ThenBy(x => x.GridReference).ToQueryString();
        Assert.That(parcelSql, Does.Contain("[CPH].[LandParcels]").And.Contain("[CPH].[Land]")
            .And.Contain("[CPH].[Customers]").And.Contain("[Audit].[Audit]").And.Contain("[CPH].[Cases]")
            .And.Contain("[Active] = CAST(1 AS bit)").And.Contain("ORDER BY"));
        Assert.That(context.Database.GetDbConnection().State, Is.EqualTo(ConnectionState.Closed));
        Assert.That(context.ChangeTracker.Entries(), Is.Empty);
    }

    [Test]
    public void HistoricalMigrations_AreNotExecutableOrEmbeddedAndEf6IsNotReferenced()
    {
        var assembly = typeof(CPHContext).Assembly;
        Assert.That(assembly.GetTypes().Any(x => x.Namespace?.Contains(".Migrations") == true), Is.False);
        Assert.That(assembly.GetManifestResourceNames().Any(x => x.Contains("Migrations")), Is.False);
        Assert.That(assembly.GetReferencedAssemblies().Any(x =>
            x.Name == "EntityFramework" || x.Name == "Microsoft.EntityFramework.SqlServer"), Is.False);
    }

    [Test]
    public void ProductionSource_HasNoAutomaticSchemaOperations()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root != null && !File.Exists(Path.Combine(root.FullName, "RPA.CPH.NonSubsidy.sln")))
            root = root.Parent;
        Assert.That(root, Is.Not.Null, "Run this source-regression guard from the repository.");
        foreach (var project in new[] { "RPA.CPH.NonSubsidy.Domain", "RPA.CPH.NonSubsidy.Web" })
        foreach (var file in Directory.EnumerateFiles(Path.Combine(root.FullName, project), "*.cs", SearchOption.AllDirectories)
            .Where(x => !Regex.IsMatch(x, @"\\(obj|bin|Migrations)\\")))
        {
            Assert.That(Regex.IsMatch(File.ReadAllText(file),
                @"\b(EnsureCreated(Async)?|EnsureDeleted(Async)?|Migrate(Async)?|DbMigrator)\s*\("), Is.False, file);
        }
    }
}
