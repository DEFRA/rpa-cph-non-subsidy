using System.Text;
using System.ComponentModel.DataAnnotations;
using System.Data.Common;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Data.Sqlite;
using Microsoft.EntityFrameworkCore;
using Microsoft.EntityFrameworkCore.Diagnostics;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Context;
using RPA.CPH.NonSubsidy.Domain.Repository;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Pages;
using RPA.CPH.NonSubsidy.Web.Models;

namespace RPA.CPH.NonSubsidy.Web.Tests;

// SQLite verifies offline relational persistence/FKs/transactions, not Azure SQL parity.
[TestClass]
[TestCategory("Integration")]
public class RelationalPersistenceTests
{
    private SqliteConnection connection;

    private sealed class TestUser : IUser
    {
        public string Name => "m1234";
    }

    private sealed class CommandTrace : DbCommandInterceptor
    {
        public List<string> Completed { get; } = [];

        public override DbDataReader ReaderExecuted(DbCommand command, CommandExecutedEventData eventData, DbDataReader result)
        {
            Completed.Add(command.CommandText);
            return result;
        }
    }

    [TestInitialize]
    public void Initialize()
    {
        connection = new SqliteConnection("Data Source=:memory:;Foreign Keys=True");
        connection.Open();
        CreateHistoricalSchema(connection);
    }

    internal static void CreateHistoricalSchema(SqliteConnection connection)
    {
        using var command = connection.CreateCommand();
        // Independently authored historical shape; never let the EF model create its own test schema.
        // SQLite has no CPH/Audit schemas and uses TEXT/INTEGER rather than SQL Server's store types.
        command.CommandText = """
            CREATE TABLE Customers (
                CustomerId INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
                SBI INTEGER NOT NULL, BusinessName TEXT NOT NULL);
            CREATE TABLE Addresses (
                AddressId INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, CustomerId INTEGER NOT NULL,
                Address1 TEXT NOT NULL, Address2 TEXT NULL, Address3 TEXT NULL, Address4 TEXT NULL,
                Address5 TEXT NULL, PostCode TEXT NOT NULL,
                FOREIGN KEY(CustomerId) REFERENCES Customers(CustomerId) ON DELETE CASCADE);
            CREATE TABLE Land (
                LandId INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, CustomerId INTEGER NOT NULL,
                County INTEGER NOT NULL, Parish INTEGER NOT NULL, Holding INTEGER NOT NULL,
                FOREIGN KEY(CustomerId) REFERENCES Customers(CustomerId) ON DELETE CASCADE);
            CREATE TABLE LandParcels (
                LandParcelId INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT, LandId INTEGER NOT NULL,
                GridReference TEXT NULL, PlaceOfBusiness INTEGER NOT NULL, Active INTEGER NOT NULL,
                FOREIGN KEY(LandId) REFERENCES Land(LandId) ON DELETE CASCADE);
            CREATE TABLE Cases (
                CustomerId INTEGER NOT NULL PRIMARY KEY, CRMCaseReferenceNumber TEXT NOT NULL,
                FOREIGN KEY(CustomerId) REFERENCES Customers(CustomerId) ON DELETE CASCADE);
            CREATE TABLE Audit (
                CustomerId INTEGER NOT NULL PRIMARY KEY, LastUpdatedBy TEXT NULL, LastUpdated datetime NOT NULL,
                FOREIGN KEY(CustomerId) REFERENCES Customers(CustomerId) ON DELETE CASCADE);
            """;
        command.ExecuteNonQuery();
    }

    [TestCleanup]
    public void Cleanup() => connection.Dispose();

    private CPHContext Context(params IInterceptor[] interceptors) => new(new DbContextOptionsBuilder<CPHContext>()
        .UseSqlite(connection).AddInterceptors(interceptors).Options);

    private static Customer Graph(int sbi = 105000001, string name = "Farm") => new(
        new Address { Address1 = "1 High Street", PostCode = "LS1 1AA" },
        new Land { County = 1, Parish = 2, Holding = 3 },
        new Case { CRMCaseReferenceNumber = "CRM1" },
        new Audit { LastUpdatedBy = "original", LastUpdated = new DateTime(2020, 1, 1) })
    {
        SBI = sbi,
        BusinessName = name
    };

    private int Seed()
    {
        using var context = Context();
        using var uow = new UnitOfWork(context);
        var customer = Graph();
        customer.Land.Single().LandParcels.AddRange(
        [
            new() { GridReference = "SK12345678", PlaceOfBusiness = true },
            new() { GridReference = "SK87654321" },
            new() { GridReference = "SK44444444", Active = false }
        ]);
        uow.CustomerRepository.Create(customer);
        uow.Commit();
        return customer.CustomerId;
    }

    private static IActionResult Save(CustomerModel page, Customer graph, bool update, string submit = "save") =>
        page.OnPost(graph, graph.Case, graph.Addresses.Single(), graph.Land.Single(),
            graph.Land.Single().LandParcels, graph.Audit, update, submit);

    [TestMethod]
    public void PageCreate_PersistsGeneratedIdsSharedKeysActiveGraphAndServerAudit()
    {
        var before = DateTime.Now;
        int id;
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            var graph = Graph();
            graph.Audit.LastUpdatedBy = "untrusted posted actor";
            graph.Land.Single().LandParcels.AddRange(
            [
                new() { GridReference = "SK12345678", PlaceOfBusiness = true },
                new() { GridReference = "SK87654321", Active = false },
                new() { GridReference = null }
            ]);
            Assert.AreEqual("/Index", ((RedirectToPageResult)Save(new CustomerModel(uow, new TestUser()).WithPageContext(), graph, false)).PageName);
            id = graph.CustomerId;
            Assert.IsTrue(id > 0);
            Assert.IsTrue(graph.Addresses.Single().AddressId > 0);
            Assert.IsTrue(graph.Land.Single().LandId > 0);
            Assert.IsTrue(graph.Land.Single().LandParcels.Single().LandParcelId > 0);
            Assert.AreEqual(id, graph.Case.CustomerId);
            Assert.AreEqual(id, graph.Audit.CustomerId);
        }
        using var verify = Context();
        var persisted = new SQLRepository<Customer>(verify).GetById(id);
        Assert.AreEqual(1, persisted.Addresses.Count);
        Assert.AreEqual(1, persisted.Land.Single().LandParcels.Count);
        Assert.AreEqual(id, persisted.Addresses.Single().CustomerId);
        Assert.AreEqual(id, persisted.Land.Single().CustomerId);
        Assert.AreEqual(persisted.Land.Single().LandId, persisted.Land.Single().LandParcels.Single().LandId);
        Assert.AreEqual("m1234", persisted.Audit.LastUpdatedBy);
        Assert.IsTrue(persisted.Audit.LastUpdated >= before && persisted.Audit.LastUpdated <= DateTime.Now);
        Assert.AreEqual(1, verify.Case.Count());
        Assert.AreEqual(1, verify.Audit.Count());
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public void PageDetachedUpdate_CopiesRowsWithoutGraphTraversalAndPersistsAudit(bool alreadyTracked)
    {
        var id = Seed();
        Customer posted;
        using (var read = Context())
            posted = new SQLRepository<Customer>(read).GetAllNoTracking().Single();
        var land = posted.Land.Single();
        var old = land.LandParcels.OrderBy(x => x.LandParcelId).ToArray();
        var omittedId = old[1].LandParcelId;
        old[0].Active = false;
        old[2].Active = true;
        var added = new LandParcel(land.LandId) { GridReference = "SK22222222", PlaceOfBusiness = true };
        var skipped = new LandParcel(land.LandId) { GridReference = "SK33333333", Active = false };
        land.LandParcels = [old[0], old[2], added, skipped, new LandParcel(land.LandId)];
        posted.BusinessName = "Updated Farm";
        posted.Addresses.Single().Address1 = "2 Updated Street";
        posted.Case.CRMCaseReferenceNumber = "CRM2";
        land.Holding = 42;
        posted.Audit.LastUpdatedBy = "untrusted posted actor";
        var before = DateTime.Now;

        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            Customer tracked = alreadyTracked ? uow.CustomerRepository.GetById(id) : null;
            Assert.IsInstanceOfType<RedirectToPageResult>(Save(new CustomerModel(uow, new TestUser()).WithPageContext(), posted, true));
            Assert.AreEqual(0, skipped.LandParcelId, "A skipped zero-key child must never be attached as Added.");
            Assert.AreEqual(EntityState.Detached, context.Entry(skipped).State);
            Assert.AreEqual(EntityState.Detached, context.Entry(posted).State);
            Assert.AreEqual(1, context.ChangeTracker.Entries<Customer>().Count(), "No duplicate tracked customer keys.");
            Assert.IsTrue(added.LandParcelId > 0);
            if (alreadyTracked)
            {
                Assert.AreSame(tracked, uow.CustomerRepository.GetById(id));
                Assert.AreEqual("Updated Farm", tracked.BusinessName);
            }
        }

        using var verify = Context();
        var persisted = new SQLRepository<Customer>(verify).GetById(id);
        Assert.AreEqual("Updated Farm", persisted.BusinessName);
        Assert.AreEqual("2 Updated Street", persisted.Addresses.Single().Address1);
        Assert.AreEqual("CRM2", persisted.Case.CRMCaseReferenceNumber);
        Assert.AreEqual(42, persisted.Land.Single().Holding);
        Assert.AreEqual("m1234", persisted.Audit.LastUpdatedBy);
        Assert.IsTrue(persisted.Audit.LastUpdated >= before && persisted.Audit.LastUpdated <= DateTime.Now);
        var parcels = persisted.Land.Single().LandParcels;
        Assert.AreEqual(4, parcels.Count, "Existing omitted rows stay; only the new active row is inserted.");
        Assert.IsFalse(parcels.Single(x => x.LandParcelId == old[0].LandParcelId).Active);
        Assert.IsTrue(parcels.Single(x => x.LandParcelId == old[2].LandParcelId).Active);
        Assert.IsTrue(parcels.Single(x => x.LandParcelId == omittedId).Active);
        Assert.AreEqual(1, parcels.Count(x => x.Active && x.PlaceOfBusiness));
        Assert.AreEqual("SK22222222", persisted.Land.Single().PlaceOfBusinessReference);
    }

    [TestMethod]
    public void RepositoryReads_EagerlyLoadEditorAndCsvGraphsAndReadOnlyQueriesStayDetached()
    {
        var id = Seed();
        Customer customer;
        LandParcel parcel;
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            customer = uow.CustomerRepository.GetById(id);
            Assert.AreSame(customer, uow.CustomerRepository.First(x => x.CustomerId == id));
            Assert.AreSame(customer, uow.CustomerRepository.FirstOrDefault(x => x.CustomerId == id));
            Assert.AreSame(customer, uow.CustomerRepository.FindBy(x => x.CustomerId == id).Single());
            Assert.AreSame(customer, uow.CustomerRepository.GetAll().Single());
            Assert.AreEqual(3, customer.Land.Single().LandParcels.Count, "Inactive rows remain editable.");
            Assert.AreEqual("1 High Street, LS1 1AA", customer.Addresses.Single().FullAddress);
            Assert.AreEqual("CRM1", customer.Case.CRMCaseReferenceNumber);
            Assert.AreEqual("original", customer.Audit.LastUpdatedBy);
            var trackedParcel = uow.LandParcelRepository.GetById(customer.Land.Single().LandParcels.First().LandParcelId);
            Assert.AreSame(customer.Land.Single(), trackedParcel.Land, "All repositories share one tracker.");
            Assert.IsNull(uow.CustomerRepository.GetById(-1));
            Assert.IsNull(uow.CustomerRepository.FirstOrDefault(x => x.CustomerId == -1));
            Assert.ThrowsExactly<InvalidOperationException>(() => uow.CustomerRepository.First(x => x.CustomerId == -1));
        }
        Assert.IsTrue(customer.Land.Single().LandParcelDetails.Contains("SK12345678"));
        Assert.AreEqual("SK12345678", customer.Land.Single().PlaceOfBusinessReference);

        using (var context = Context())
        {
            customer = new SQLRepository<Customer>(context).GetAllNoTracking().Single();
            parcel = new SQLRepository<LandParcel>(context).GetAllNoTracking().First(x => x.Active);
            Assert.AreEqual(0, context.ChangeTracker.Entries().Count());
            Assert.AreEqual(3, parcel.Land.LandParcels.Count);
            customer.BusinessName = "Read-only edit";
            parcel.GridReference = "Read-only edit";
            context.SaveChanges();
        }
        Assert.IsTrue(parcel.ToCSV().Contains("\"CRM1\",\"original\""), "CSV must work after context disposal.");
        Assert.AreEqual("CRM1", customer.Case.CRMCaseReferenceNumber);
        using var verify = Context();
        Assert.AreEqual("Farm", verify.Customers.Single().BusinessName);
        Assert.IsFalse(verify.LandParcels.Any(x => x.GridReference == "Read-only edit"));
    }

    [TestMethod]
    public void PageListSearchAndExtract_UsePersistedGraphsAndActiveRows()
    {
        Seed();
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            var second = Graph(105000000, "Second Farm");
            second.Audit.LastUpdated = new DateTime(2021, 1, 1);
            second.Land.Single().LandParcels.Add(new LandParcel { GridReference = "AB12345678", PlaceOfBusiness = true });
            uow.CustomerRepository.Create(second);
            uow.Commit();
        }
        using var read = Context();
        using var work = new UnitOfWork(read);
        var page = new IndexModel(work).WithPageContext();
        page.OnGet();
        var list = page.Customers;
        Assert.AreEqual(2, list.Count);
        Assert.AreEqual(105000000, list[0].SBI, "Audit descending, then SBI ordering is preserved.");
        page.OnGet(" 105000001 ");
        var filtered = page.Customers;
        Assert.AreEqual("Farm", filtered.Single().BusinessName);
        page.OnGet("10500000");
        Assert.AreEqual(0, page.Customers.Count);
        var csv = Encoding.UTF8.GetString(((FileContentResult)new ExtractModel(work).OnGet()).FileContents);
        var rows = csv.Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries);
        Assert.AreEqual(4, rows.Length, "One header and three active parcels; inactive row excluded.");
        StringAssert.StartsWith(rows[1], "\"105000000\",\"Second Farm\"");
        StringAssert.Contains(rows[2], "\"SK12345678\",\"SK12345678\",\"CRM1\",\"original\"");
        StringAssert.Contains(rows[3], "\"SK12345678\",\"SK87654321\",\"CRM1\",\"original\"");
        Assert.IsFalse(csv.Contains("SK44444444"));
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public void ControllerDelete_CascadesEveryDependentWithOrWithoutLoadedGraph(bool loadGraph)
    {
        var id = Seed();
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            if (loadGraph) uow.CustomerRepository.GetById(id);
            var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
            controller.ModelState.AddModelError("SBI", "Invalid SBI.");
            Assert.IsInstanceOfType<RedirectToPageResult>(
                Save(controller, new Customer(new Address(), new Land(), new Case(), new Audit())
                    { CustomerId = id }, true, "delete"));
        }
        using var verify = Context();
        Assert.AreEqual(0, verify.Customers.Count());
        Assert.AreEqual(0, verify.Addresses.Count());
        Assert.AreEqual(0, verify.Land.Count());
        Assert.AreEqual(0, verify.LandParcels.Count());
        Assert.AreEqual(0, verify.Case.Count());
        Assert.AreEqual(0, verify.Audit.Count());
    }

    [TestMethod]
    public void Commit_ForeignKeyFailureRollsBackCustomerAuditAndEarlierStatements()
    {
        var id = Seed();
        var commands = new CommandTrace();
        using (var context = Context(commands))
        using (var uow = new UnitOfWork(context))
        {
            uow.CustomerRepository.Update(new Customer { CustomerId = id, SBI = 105000001, BusinessName = "Must roll back" });
            uow.AuditRepository.Update(new Audit { CustomerId = id, LastUpdatedBy = "Must roll back", LastUpdated = DateTime.Now });
            uow.AddressRepository.Create(new Address { CustomerId = id, Address1 = "Must roll back", PostCode = "LS1 1AA" });
            uow.LandParcelRepository.Create(new LandParcel(int.MaxValue) { GridReference = "SK55555555" });
            Assert.ThrowsExactly<DbUpdateException>(() => uow.Commit());
            Assert.IsTrue(commands.Completed.Any(x => x.Contains("INSERT INTO \"Addresses\"")),
                "A successful write must precede the FK failure, so this tests rollback rather than pre-validation.");
        }
        using var verify = Context();
        Assert.AreEqual("Farm", verify.Customers.Single().BusinessName);
        Assert.AreEqual("original", verify.Audit.Single().LastUpdatedBy);
        Assert.AreEqual(new DateTime(2020, 1, 1), verify.Audit.Single().LastUpdated);
        Assert.AreEqual(1, verify.Addresses.Count());
        Assert.AreEqual(3, verify.LandParcels.Count());
    }

    [TestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public void Commit_ValidatesLegacyDataAnnotationsBeforeWritingAnyChanges(bool invalidParcel)
    {
        var id = Seed();
        var commands = new CommandTrace();
        using (var context = Context(commands))
        using (var work = new UnitOfWork(context))
        {
            var graph = work.CustomerRepository.GetById(id);
            if (invalidParcel)
                graph.Land.Single().LandParcels.First(x => x.Active).GridReference = "invalid";
            else
                graph.SBI = 1;
            graph.Audit.Update("must not persist");
            Assert.ThrowsExactly<ValidationException>(() => work.Commit());
            Assert.IsFalse(commands.Completed.Any(x => x.StartsWith("UPDATE ") || x.StartsWith("INSERT ")));
        }
        using var verify = Context();
        Assert.AreEqual(105000001, verify.Customers.Single().SBI);
        Assert.IsFalse(verify.LandParcels.Any(x => x.GridReference == "invalid"));
        Assert.AreEqual("original", verify.Audit.Single().LastUpdatedBy);
    }

    [TestMethod]
    public async Task SaveChangesAsync_ValidatesAnnotationsAndPersistsValidGraph()
    {
        using (var context = Context())
        {
            var graph = Graph(sbi: 1);
            context.Customers.Add(graph);
            await Assert.ThrowsExactlyAsync<ValidationException>(() => context.SaveChangesAsync());
            Assert.AreEqual(0, await context.Customers.CountAsync());
            graph.SBI = 105000001;
            await context.SaveChangesAsync();
        }
        using var verify = Context();
        Assert.AreEqual(1, verify.Customers.Count());
        Assert.AreEqual(verify.Customers.Single().CustomerId, verify.Audit.Single().CustomerId);
        Assert.AreEqual(verify.Customers.Single().CustomerId, verify.Case.Single().CustomerId);
    }

    [TestMethod]
    public void RepositoryUpdate_DoesNotInsertMissingOrZeroGeneratedKeys()
    {
        Seed();
        using var context = Context();
        var repository = new SQLRepository<LandParcel>(context);
        Assert.ThrowsExactly<DbUpdateConcurrencyException>(() =>
            repository.Update(new LandParcel { LandParcelId = int.MaxValue, LandId = 1 }));
        Assert.ThrowsExactly<DbUpdateConcurrencyException>(() =>
            repository.Update(new LandParcel { LandId = 1 }));
        Assert.AreEqual(0, context.ChangeTracker.Entries().Count());
        Assert.AreEqual(3, context.LandParcels.Count());
    }

    [TestMethod]
    public void RepositoryDelete_DetachedRowUsesTrackedKeyAndLeavesOtherRows()
    {
        var id = Seed();
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            var loaded = uow.CustomerRepository.GetById(id);
            var parcel = loaded.Land.Single().LandParcels.First(x => !x.PlaceOfBusiness);
            uow.LandParcelRepository.Delete(new LandParcel { LandParcelId = parcel.LandParcelId });
            uow.Commit();
            Assert.ThrowsExactly<ArgumentNullException>(() => uow.LandParcelRepository.Delete(int.MaxValue));
        }
        using var verify = Context();
        Assert.AreEqual(2, verify.LandParcels.Count());
        Assert.AreEqual(1, verify.Customers.Count());
    }

    [TestMethod]
    public void DuplicateSbi_RemainsAllowedAndSharedKeyDependentsCannotOutliveCustomer()
    {
        Seed();
        using (var context = Context())
        using (var uow = new UnitOfWork(context))
        {
            uow.CustomerRepository.Create(Graph());
            uow.Commit();
            Assert.AreEqual(2, context.Customers.Count(x => x.SBI == 105000001));
            uow.AuditRepository.Create(new Audit { CustomerId = int.MaxValue, LastUpdated = DateTime.Now });
            Assert.ThrowsExactly<DbUpdateException>(() => uow.Commit());
        }
        using var verify = Context();
        Assert.AreEqual(2, verify.Customers.Count());
        Assert.AreEqual(2, verify.Audit.Count());
    }
}
