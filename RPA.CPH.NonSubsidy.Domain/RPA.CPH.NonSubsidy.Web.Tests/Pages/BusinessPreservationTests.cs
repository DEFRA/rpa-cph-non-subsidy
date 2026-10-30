using System.Globalization;
using System.Text;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.RazorPages;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.Interfaces;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Pages;
using RPA.CPH.NonSubsidy.Web.Models;

namespace RPA.CPH.NonSubsidy.Web.Tests.Pages;

[TestClass]
[TestCategory("Unit")]
public class BusinessPreservationTests
{
    private sealed class TestUser : IUser
    {
        public string Name => "m1234";
    }

    private sealed class CountingUnitOfWork : IUnitOfWork
    {
        private readonly FakeUnitOfWork inner = new();
        public IRepository<Customer> CustomerRepository => inner.CustomerRepository;
        public IRepository<Address> AddressRepository => inner.AddressRepository;
        public IRepository<Land> LandRepository => inner.LandRepository;
        public IRepository<LandParcel> LandParcelRepository => inner.LandParcelRepository;
        public IRepository<Case> CaseRepository => inner.CaseRepository;
        public IRepository<Audit> AuditRepository => inner.AuditRepository;
        public int Commits { get; private set; }
        public void Commit() => Commits++;
        public void Dispose() => inner.Dispose();
    }

    private static IActionResult Save(CustomerModel page, Customer customer, List<LandParcel> parcels, bool update = false, string submit = "save") =>
        page.OnPost(customer, new Case { CRMCaseReferenceNumber = "CRM1" },
            new Address { Address1 = "1 High Street", PostCode = "LS1 1AA" }, new Land { County = 1, Parish = 2, Holding = 3 },
            parcels, new Audit { LastUpdatedBy = "untrusted posted audit", LastUpdated = new DateTime(2000, 1, 1) },
            update, submit);

    [TestMethod]
    [DataRow(0, "One POB is required.")]
    [DataRow(2, "One POB is allowed.")]
    public void Save_RejectsInvalidActivePobWithoutAuditOrCommit(int pobs, string error)
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        var customer = new Customer();
        var parcels = new List<LandParcel>
        {
            new() { GridReference = "SK12345678", Active = true, PlaceOfBusiness = pobs > 0 },
            new() { GridReference = "SK87654321", Active = true, PlaceOfBusiness = pobs > 1 }
        };
        Assert.IsInstanceOfType<PageResult>(Save(controller, customer, parcels));
        Assert.AreSame(customer, controller.Customer);
        Assert.AreEqual(error, controller.ModelState["POB"].Errors.Single().ErrorMessage);
        Assert.AreEqual(0, uow.Commits);
        Assert.AreEqual("untrusted posted audit", customer.Audit.LastUpdatedBy);
    }

    [TestMethod]
    public void Save_RejectsExactActiveGridDuplicates()
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        var parcels = new List<LandParcel>
        {
            new() { GridReference = "SK12345678", Active = true, PlaceOfBusiness = true },
            new() { GridReference = "SK12345678", Active = true }
        };
        Assert.IsInstanceOfType<PageResult>(Save(controller, new Customer(), parcels));
        Assert.AreEqual("Duplicate Grid Reference identified.",
            controller.ModelState["GridReference"].Errors.Single().ErrorMessage);
        Assert.AreEqual(0, uow.Commits);
    }

    [TestMethod]
    public void Save_UsesCaseSensitiveUntrimmedGroupingAndPobRejectionPrecedesDuplicates()
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        var parcels = new List<LandParcel>
        {
            new() { GridReference = "SK12345678", PlaceOfBusiness = true },
            new() { GridReference = "sk12345678" },
            new() { GridReference = "SK12345678\n" },
            new() { GridReference = "SK12345678 ", Active = false }
        };
        Assert.AreEqual("/Index", ((RedirectToPageResult)Save(controller, new Customer(), parcels)).PageName);
        Assert.AreEqual(1, uow.Commits);
        Assert.AreEqual(3, uow.CustomerRepository.GetAll().Single().Land.Single().LandParcels.Count);
        controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        parcels =
        [
            new() { GridReference = "SK12345678" },
            new() { GridReference = "SK12345678" }
        ];
        Assert.IsInstanceOfType<PageResult>(Save(controller, new Customer(), parcels));
        Assert.AreEqual("One POB is required.", controller.ModelState["POB"].Errors.Single().ErrorMessage);
        Assert.IsFalse(controller.ModelState.ContainsKey("GridReference"));
        Assert.AreEqual(1, uow.Commits);
    }

    [TestMethod]
    [DataRow("en-GB")]
    [DataRow("fr-FR")]
    public void Extract_MultipleCustomersPreserveFullFilenameCultureAndNewlinesWithEscapedQuotes(string culture)
    {
        var previous = CultureInfo.CurrentCulture;
        try
        {
            CultureInfo.CurrentCulture = CultureInfo.GetCultureInfo(culture);
            using var uow = new CountingUnitOfWork();
            var before = DateTime.Now;
            var date = new DateTime(2026, 12, 31, 23, 59, 59);
            var land = new Land { County = 99, Parish = 999, Holding = 9999 };
            var first = new Customer(new Address { Address1 = "A,\n\"B\"", PostCode = "LS1 1AA" },
                land, new Case { CRMCaseReferenceNumber = "CRM-first" },
                new Audit { LastUpdatedBy = "actor", LastUpdated = date })
            { SBI = 105000000, BusinessName = "Färm,\"one\"" };
            land.Customer = first;
            land.LandParcels =
            [
                new() { Land = land, GridReference = "ZZ99999999" },
                new() { Land = land, GridReference = "AA00000000", PlaceOfBusiness = true }
            ];
            var otherLand = new Land { County = 1, Parish = 1, Holding = 1 };
            var second = new Customer(new Address { Address1 = "Second", PostCode = "LS1 1AA" },
                otherLand, new Case { CRMCaseReferenceNumber = "CRM-second" },
                new Audit { LastUpdatedBy = "other", LastUpdated = DateTime.MinValue })
            { SBI = 300000000, BusinessName = "Second" };
            otherLand.Customer = second;
            var otherParcel = new LandParcel { Land = otherLand, GridReference = "BB11111111", PlaceOfBusiness = true };
            otherLand.LandParcels.Add(otherParcel);
            uow.LandParcelRepository.Create(otherParcel);
            foreach (var parcel in land.LandParcels) uow.LandParcelRepository.Create(parcel);
            uow.LandParcelRepository.Create(new LandParcel { Active = false, GridReference = "inactive" });
            var extract = (FileContentResult)new ExtractModel(uow).OnGet();
            var after = DateTime.Now;
            const string header = "SBI,BusinessName,BusinessAddress,CPH,PlaceOfBusinessReferenceNumber,AdditionalGridReferences,CRMCaseReferenceNumber,UpdatedBy,Updated";
            var expected = header + Environment.NewLine +
                $"\"105000000\",\"Färm,\"\"one\"\"\",\"A,\n\"\"B\"\", LS1 1AA\",\"99/999/9999\",\"AA00000000\",\"AA00000000\",\"CRM-first\",\"actor\",\"{date}\"" + Environment.NewLine +
                $"\"105000000\",\"Färm,\"\"one\"\"\",\"A,\n\"\"B\"\", LS1 1AA\",\"99/999/9999\",\"AA00000000\",\"ZZ99999999\",\"CRM-first\",\"actor\",\"{date}\"" + Environment.NewLine +
                $"\"300000000\",\"Second\",\"Second, LS1 1AA\",\"01/001/0001\",\"BB11111111\",\"BB11111111\",\"CRM-second\",\"other\",\"{DateTime.MinValue}\"" + Environment.NewLine;
            CollectionAssert.AreEqual(new UTF8Encoding(false).GetBytes(expected), extract.FileContents);
            Assert.AreEqual("text/csv", extract.ContentType);
            static string Filename(DateTime value) => $"Non_Subsidy_CPHs_{value.Day}{value.Month}{value.Year}{value.Hour}{value.Minute}.csv";
            Assert.IsTrue(extract.FileDownloadName == Filename(before) || extract.FileDownloadName == Filename(after),
                "Full unpadded local filename, allowing the minute/date boundary during the call.");
            using var empty = new CountingUnitOfWork();
            var emptyExtract = (FileContentResult)new ExtractModel(empty).OnGet();
            CollectionAssert.AreEqual(Encoding.UTF8.GetBytes(header + Environment.NewLine), emptyExtract.FileContents);
        }
        finally
        {
            CultureInfo.CurrentCulture = previous;
        }
    }

    [TestMethod]
    public void Create_KeepsOnlyActiveNonblankRowsAndStampsAudit()
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        var customer = new Customer();
        var before = DateTime.Now;
        var parcels = new List<LandParcel>
        {
            new() { GridReference = "SK12345678", Active = true, PlaceOfBusiness = true },
            new() { GridReference = "SK12345678", Active = false, PlaceOfBusiness = true },
            new() { GridReference = null, Active = true }
        };
        Assert.IsInstanceOfType<RedirectToPageResult>(Save(controller, customer, parcels));
        Assert.AreEqual(1, uow.Commits);
        Assert.AreSame(customer, uow.CustomerRepository.GetAll().Single());
        Assert.AreEqual(1, customer.Land.Single().LandParcels.Count);
        Assert.AreEqual("m1234", customer.Audit.LastUpdatedBy);
        Assert.IsTrue(customer.Audit.LastUpdated >= before && customer.Audit.LastUpdated <= DateTime.Now);
    }

    [TestMethod]
    public void Create_WithNoParcelsIsAllowed()
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        var customer = new Customer();
        Assert.IsInstanceOfType<RedirectToPageResult>(Save(controller, customer, null));
        Assert.AreEqual(0, customer.Land.Single().LandParcels.Count);
        Assert.AreEqual(1, uow.Commits);
    }

    [TestMethod]
    public void InvalidModelState_DoesNotStampOrCommit()
    {
        using var uow = new CountingUnitOfWork();
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        controller.ModelState.AddModelError("SBI", "Invalid SBI.");
        var customer = new Customer();
        Assert.IsInstanceOfType<PageResult>(Save(controller, customer, null));
        Assert.AreEqual(0, uow.Commits);
        Assert.AreEqual("untrusted posted audit", customer.Audit.LastUpdatedBy);
    }

    [TestMethod]
    public void Delete_PrecedesModelStateAndAuditValidation()
    {
        using var uow = new CountingUnitOfWork();
        var customer = new Customer { CustomerId = 42 };
        uow.CustomerRepository.Create(customer);
        var controller = new CustomerModel(uow, new TestUser()).WithPageContext();
        controller.ModelState.AddModelError("SBI", "Invalid SBI.");
        Assert.IsInstanceOfType<RedirectToPageResult>(Save(controller, customer, null, submit: "delete"));
        Assert.AreEqual(0, uow.CustomerRepository.GetAll().Count());
        Assert.AreEqual(1, uow.Commits);
        Assert.IsNull(customer.Audit);
    }

}
