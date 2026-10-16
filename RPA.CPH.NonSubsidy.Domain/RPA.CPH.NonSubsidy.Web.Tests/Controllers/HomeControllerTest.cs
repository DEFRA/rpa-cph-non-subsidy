using Microsoft.AspNetCore.Mvc;
using Microsoft.VisualStudio.TestTools.UnitTesting;
using RPA.CPH.NonSubsidy.Domain.Classes.Audit;
using RPA.CPH.NonSubsidy.Domain.Classes.CPH;
using RPA.CPH.NonSubsidy.Domain.UnitOfWork;
using RPA.CPH.NonSubsidy.Web.Controllers;
using RPA.CPH.NonSubsidy.Web.Models;
using System.Text;
using X.PagedList;

namespace RPA.CPH.NonSubsidy.Web.Tests.Controllers
{
    [TestClass]
    public class HomeControllerTest
    {
        private class StubUser : IUser
        {
            public string Name => "tester";
        }

        private static Customer CreateCustomer(int sbi)
        {
            var land = new Land { County = 1, Parish = 2, Holding = 3 };
            land.LandParcels.Add(new LandParcel { GridReference = "SK12345678", PlaceOfBusiness = true });

            var customer = new Customer(
                new Address { Address1 = "1 High Street", PostCode = "LS1 1AA" },
                land,
                new Case { CRMCaseReferenceNumber = "CRM1" },
                new Audit { LastUpdatedBy = "tester", LastUpdated = DateTime.Now })
            {
                SBI = sbi,
                BusinessName = "Test Farm"
            };

            land.Customer = customer;
            land.LandParcels[0].Land = land;

            return customer;
        }

        [TestMethod]
        public void Index_ReturnsPagedCustomers()
        {
            var uow = new FakeUnitOfWork();
            uow.CustomerRepository.Create(CreateCustomer(105000001));
            var controller = new HomeController(uow, new StubUser());

            var result = controller.Index() as ViewResult;

            Assert.IsNotNull(result);
            var model = result.Model as IPagedList<Customer>;
            Assert.IsNotNull(model);
            Assert.AreEqual(1, model.Count);
        }

        [TestMethod]
        public void Customer_WithoutId_ReturnsNewCustomerForCreate()
        {
            var controller = new HomeController(new FakeUnitOfWork(), new StubUser());

            var result = controller.Customer() as ViewResult;

            Assert.IsNotNull(result);
            Assert.IsInstanceOfType<Customer>(result.Model);
            Assert.AreEqual(false, controller.ViewBag.IsUpdate);
        }

        [TestMethod]
        public void Extract_ReturnsCsvOfActiveLandParcels()
        {
            var uow = new FakeUnitOfWork();
            var customer = CreateCustomer(105000001);
            uow.LandParcelRepository.Create(customer.Land[0].LandParcels[0]);
            var controller = new HomeController(uow, new StubUser());

            var result = controller.Extract() as FileContentResult;

            Assert.IsNotNull(result);
            Assert.AreEqual("text/csv", result.ContentType);
            var csv = Encoding.UTF8.GetString(result.FileContents);
            StringAssert.Contains(csv, "105000001");
            StringAssert.Contains(csv, "01/002/0003");
        }
    }
}
